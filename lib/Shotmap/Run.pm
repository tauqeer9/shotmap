#!/usr/bin/perl -w

#Shotmap::Run.pm - Handles workhorse methods in the shotmap workflow
#Copyright (C) 2011  Thomas J. Sharpton 
#author contact: thomas.sharpton@gladstone.ucsf.edu
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#    
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#    
#You should have received a copy of the GNU General Public License
#along with this program (see LICENSE.txt).  If not, see 
#<http://www.gnu.org/licenses/>.

package Shotmap::Run;

use lib ($ENV{'SHOTMAP_LOCAL'} . "/ext/lib/perl5");     

use strict;
use Shotmap;

use Shotmap::DB;
use Data::Dumper;
use File::Basename;
use File::Cat;
use File::Copy qw( move copy );
use File::Path qw( make_path rmtree );
use IPC::System::Simple qw(capture system run $EXITVAL);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Compress::Gzip qw(gzip $GzipError);
#use DBIx::Class::ResultClass::HashRefInflator;
use Benchmark;
use File::Spec;
use List::Util qw( shuffle );
use Math::Random qw( :all );
use Parallel::ForkManager;
use POSIX;

# ServerAliveInterval : in SECONDS
# ServerAliveCountMax : number of times to keep the connection alive
# Total keep-alive time in minutes = (ServerAliveInterval*ServerAliveCountMax)/60 minutes
my $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING = '-o TCPKeepAlive=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=480';

my $HMMDB_DIR = "HMMdbs";
my $BLASTDB_DIR = "BLASTdbs";

sub remote_transfer_scp{
    my ($self, $src_path, $dest_path, $path_type) = @_;
    ($path_type eq 'directory' or $path_type eq 'file') or die "unsupported path type! must be 'file' or 'directory'. Yours was: '$path_type'.";
    my $COMPRESSION_FLAG = '-C';
    my $PRESERVE_MODIFICATION_TIMES = '-p';
    my $RECURSIVE_FLAG = ($path_type eq 'directory') ? '-r' : ''; # only specify recursion if DIRECTORIES are being transferred!
    my $FLAGS = "$COMPRESSION_FLAG $RECURSIVE_FLAG $PRESERVE_MODIFICATION_TIMES";
    my @args = ($FLAGS, $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING, $src_path, $dest_path);
    $self->Shotmap::Notify::notifyAboutScp("scp @args");
    my $results = IPC::System::Simple::capture("scp @args");
    (0 == $EXITVAL) or die("Error transferring $src_path to $dest_path using $path_type: $results");
    return $results;
}

#rolling over to rsync for directories
sub remote_transfer {
    my ($self, $src_path, $dest_path, $path_type) = @_;
    ($path_type eq 'directory' or $path_type eq 'file') or die "unsupported path type! must be 'file' or 'directory'. Yours was: '$path_type'.";
    my $COMPRESSION_FLAG = '--compress';
    my $PRESERVE_MODIFICATION_TIMES = ''; #'--times'; #turned off because of autodeletion tool on cluster
    my $PRESERVE_PERMISSIONS_FLAG = '--perms';
    my $RECURSIVE_FLAG = ($path_type eq 'directory') ? '--recursive' : ''; # only specify recursion if DIRECTORIES are being transferred!
    my $FLAGS = "$COMPRESSION_FLAG $RECURSIVE_FLAG $PRESERVE_MODIFICATION_TIMES $PRESERVE_PERMISSIONS_FLAG";
    #my @args = ($FLAGS, $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING, $src_path, $dest_path);
    my @args = ($FLAGS, $src_path, $dest_path);
    $self->Shotmap::Notify::notifyAboutScp("rsync @args");
    my $results = IPC::System::Simple::capture("rsync @args");
    (0 == $EXITVAL) or die("Error transferring $src_path to $dest_path using $path_type: $results");
    return $results;
}


sub ends_in_a_slash($) { return ($_[0] =~ /\/$/); } # return whether or not the first (and only) argument to this function ends in a forward slash (/)

sub transfer_file {
    my ($self, $src_path, $dest_path) = @_;
    (!ends_in_a_slash($src_path))  or die "Since you are transferring a FILE to a new FILE location, the source must not end in a slash.  Your source was <$src_path>, and destination was <$dest_path>.";
    (!ends_in_a_slash($dest_path)) or die "Since you are transferring a FILE to a new FILE location, the destination must not end in a slash. This will be the new location of the file, NOT the name of the parent directory. Your source was <$src_path>, and destination was <$dest_path>. If you want to transfer a file INTO a directory, use the function transfer_file_into_directory instead.";
    return( $self->Shotmap::Run::remote_transfer($src_path, $dest_path, 'file'));
}

sub transfer_directory{
    # Transfer a directory between machines / locations.
    # Example:
    # src_path:  remote.machine.place.ed:/somewhere/over/the/rainbow
    # dest_path:  /local/machine/rainbow
    # Note that the last directory ("rainbow") must be the same in both cases! You CANNOT use this function to rename files while they are transferred.
    # Also, src_path and dest_path must both NOT end in slashes!
    my ($self, $src_path, $dest_path) = @_;
    my $src_base  = File::Basename::basename($src_path );
    my $dest_base = File::Basename::basename($dest_path);
    (!ends_in_a_slash($src_path))  or die "Since you are transferring a DIRECTORY, the source must not end in a slash.  Your source was <$src_path>, and destination was <$dest_path>.";
    (!ends_in_a_slash($dest_path)) or die "Since you are transferring a DIRECTORY, the destination must not end in a slash. This will be the new location of the directory, NOT the name of the parent directory. Your source was <$src_path>, and destination was <$dest_path>.";
    ($src_base eq $dest_base) or die "Directory transfer problem: The last directory in the source path \"$src_path\" must exactly match the last directory in the \"$dest_path\"! Example: transferring /some/place to /other/place is OK, but transferring /some/place to /other/placeTWO is NOT OK, because the ending of the source part ('place') is different from the ending of the destination part ('placeTWO')!";
    my $dest_parent_dir_with_slash = File::Basename::dirname($dest_path) . "/"; # include the slash so we don't actually OVERWRITE this directory if it doesn't already exist
    return( $self->Shotmap::Run::remote_transfer($src_path, $dest_parent_dir_with_slash, 'directory'));
}

sub transfer_file_into_directory {
    # source: a file (that does NOT end in a slash!)
    # destination: a directory (that ends with a slash!)
    my ($self, $src_path, $dest_path) = @_;
    (!ends_in_a_slash($src_path)) or die "Since you are transferring a FILE, the source must not end in a slash (the slash indicates that the source is a DIRECTORY, which is probably incorrect). Your source file was <$src_path> and destination file was <$dest_path>.";
    (ends_in_a_slash($dest_path)) or die "Since you are transferring a file INTO a directory, the destination path MUST END IN A SLASH (indicating that it is a destination directory. Otherwise, it is ambiguous as to whether you want to transfer the file INTO the directory, or if you want the file to be written to OVERWRITE that directory. Your source file was <$src_path> and destination file was <$dest_path>.";
    return( $self->Shotmap::Run::remote_transfer($src_path, $dest_path, 'file'));
}


sub execute_ssh_cmd{
    my ($self, $connection, $remote_cmd, $verbose) = @_;
    my $verboseFlag = (defined($verbose) && $verbose) ? '-v' : '';
    my $sshOptions = "ssh $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING $verboseFlag $connection";
    $self->Shotmap::Notify::notifyAboutRemoteCmd($sshOptions);
    if( defined( $self->bash_source() ) ){
	$remote_cmd = "source " . $self->bash_source . "; ${remote_cmd}";
    }
    #add single ticks around the command
    $remote_cmd = "\'${remote_cmd}\'";
    $self->Shotmap::Notify::notifyAboutRemoteCmd($remote_cmd);
    my $results = IPC::System::Simple::capture("$sshOptions $remote_cmd");
    (0 == $EXITVAL) or die( "Error running this ssh command: $sshOptions $remote_cmd: $results" );
    return $results; ## <-- this gets used! Don't remove it.
}


sub get_sequence_length_from_file($) {
    my($file) = shift;
    #my $READSTRING = ($file =~ m/\.gz/ ) ? "zmore $file | " : "$file"; # allow transparent reading of gzipped files via 'zmore'
    open(FILE, "zcat --force $file |") || die "Unable to open the file \"$file\" for reading: $! --"; # zcat --force can TRANSPARENTLY read both .gz and non-gzipped files!
    my $seqLength = 0;
    while(<FILE>){
	next if ($_ =~ m/^\>/); # skip lines that start with a '>'
	chomp $_; # remove the newline
	$seqLength += length($_);
    }
    close FILE;
    if ($seqLength == 0) { warn "Uh oh, we got a sequence length of ZERO from the file <$file>. This could indicate a serious problem!"; }
    return $seqLength; # return the sequence length
}

sub gzip_file($) {
    my($file) = @_;
    IO::Compress::Gzip::gzip $file => "${file}.gz" or die "gzip failed: $GzipError ";
}

sub clean_project{
    my ($self, $project_id) = @_;
    my $samples = $self->Shotmap::DB::get_samples_by_project_id( $project_id ); # apparently $samples is a scalar datatype that we can iterate over
    $self->Shotmap::DB::delete_project( $project_id );
    $self->Shotmap::DB::delete_ffdb_project( $project_id );
}

sub exec_remote_cmd($$) {
    my ($self, $remote_cmd) = @_;
    my $connection = $self->remote_connection();
    if ($remote_cmd =~ /\'/) {
	die "Remote commands aren't allowed to include the single quote character currently. Sorry!";
    }
    my $sshCmd = "ssh $GLOBAL_SSH_TIMEOUT_OPTIONS_STRING -v $connection '$remote_cmd' "; # remote-cmd gets single quotes around it!
    $self->Shotmap::Notify::notifyAboutRemoteCmd($sshCmd);
    my $results = IPC::System::Simple::capture($sshCmd);
    (0 == $EXITVAL) or die( "Error running this remote command: $sshCmd: $results" );
    return $results; ## <-- this gets used! Don't remove it.
}

sub parse_sample_metadata{
    my( $self ) = @_;
    if( defined( $self->metadata_file ) ){
	my $file = $self->metadata_file;
	$self->Shotmap::Notify::print_verbose( "Parsing metadata from $file\n" );
	my $text = '';
	open( META, "$file" ) || die "Can't open sample metadata table for read: $!. Project is $file.\n";
	while(<META>){
	    $text .= $_;
	    #check that the file is properly formatted	   
	    if( $text !~ m/^Sample\.Name\t/ ){
		die( "You did not specify a properly formatted metadata file. " .
		     "Please ensure that the first column in the " .
		     "first row is named 'Sample.Name' (without quotes) and that the " .
		     "file is tab delimited.\n"
		    ); 
	    }	   
	    if( $text =~ m/\,/ ){
		die( "You have commas in your metadata file. This is not allowed. Please reformat " .
		     "the file and try again.\n" );
	    }
	    my @rows  = split( "\n", $text );
	    my $ncols = 0;
	    foreach my $row( @rows ){
		my @cols = split( "\t", $row );
		my $row_n_col = scalar( @cols );
		if( $ncols == 0 ){
		    $ncols = $row_n_col;
		} elsif( $ncols != $row_n_col) {
		    die( "You do not have an equal number of tab-delimited columns in every row " .
			 "of your metadata file. Please double check " .
			 "your format.\n" 
			);
		} else { #looks good
		    next;
		}
	    }
	    undef $text if( $text eq '' );
	    $self->sample_metadata($text);
	}
	close META;
    } else {
	$self->Shotmap::Notify::print_verbose( "You didn't provide a sample metadata file, which is optional. " . 
					      "and can be specified with the -m option"
	    );
    }
    return $self;
}

sub get_sample_from_file{
    my( $self, $path ) = @_;
    my %samples = ();
    if( ! defined( $path ) || ! -f $path ){
	die "You either have not specified or I cannot file the raw data location. Please double check " .
	    "how the option --input is set and that this directory exists\n";
    }
    my $is_compressed = 0;
    if( $path =~ m/\.gz$/ ){
	$is_compressed = 1;
    }
    my $is_fasta = $self->Shotmap::Run::check_fasta_file( "$path", "nt", $is_compressed );
    if( !$is_fasta ){
	$self->Shotmap::Notify::warn( "$path doesn't look like a properly formatted fasta file! Terminating!\n" );
	die;
    }
    #get sample name here, simple parse on the period in file name
    my $thisSample;
    if( $is_compressed ){
	$thisSample = basename($path, (".fa.gz", ".fna.gz"));
    } else {
	$thisSample = basename($path, (".fa", ".fna"));
    }
    $samples{$thisSample}->{"path"} = "$path";
    $self->set_samples( \%samples );
    return $self;
}

#currently uses @suffix with basename to successfully parse off .fa. may need to change
sub get_partitioned_samples{
    my ($self, $path) = @_;
    my %samples = ();        
    if( ! defined( $path ) || ! -d $path ){
	die "You either have not specified or I cannot file the raw data location. Please double check " .
	    "how the option --input is set and that this directory exists\n";
    }
    opendir( PROJ, $path ) || die "Can't open the directory $path for read: $!\n";     #open the directory and get the sample names and paths, 
    my @files = readdir(PROJ);
    closedir(PROJ);
    foreach my $file (@files) {
	next if ( $file =~ m/^\./ );
	next if ( -d "$path/$file" ); 
	#if there's a project description file, grab the information
	if($file =~ m/project_description\.txt/){ # <-- see if there's a description file
	    my $text = '';
	    open(DESC, "$path/$file") || die "Can't open project description file $file for read: $!. Project is $path.\n";
	    while(<DESC>){
		$text .= $_; # append the line
	    }
	    close(DESC);
	    undef $text if( $text eq '' );
	    $self->project_desc($text);
	} else { #is a sample sequence file
	    #is it properly formatted?
	    my $is_compressed = 0;
	    if( $file =~ m/\.gz$/ ){
		$is_compressed = 1;
	    }
	    my $is_fasta = $self->Shotmap::Run::check_fasta_file( "$path/$file", "nt", $is_compressed );
	    if( !$is_fasta ){
		$self->Shotmap::Notify::warn( "$file doesn't look like a properly formatted fasta file, passing\n" );
		next;
	    }
	    #get sample name here, simple parse on the period in file name
	    my $thisSample;
	    if( $is_compressed ){
		$thisSample = basename($file, (".fa.gz", ".fna.gz"));
	    } else {
		$thisSample = basename($file, (".fa", ".fna"));
	    }
	    $samples{$thisSample}->{"path"} = "$path/$file";
	}	
    }
    if( !defined( $self->project_desc() ) ){
	# Project description files are only for mysql runs, which involve advanced users. Ignore for now.
	#$self->Shotmap::Notify::warn( "You didn't provide a project description file, which is optional. " .
	#     "Note that you can describe your project in the database via a project_description.txt file. " .
	#     "See manual for more information\n" 
	#);
    }
    $self->Shotmap::Notify::print_verbose("Adding samples to analysis object at path <$path>.");
    $self->set_samples( \%samples );
    return $self;
}

sub check_fasta_file{
    my( $self, $file, $type, $is_compressed ) = @_;
    my $fh;
    if( $is_compressed ){
	open( $fh, "zcat $file|" ) || die "Can't open $file for read: $!\n";
    } else {
	open( $fh, $file ) || die "Can't open $file for read: $!\n";
    }
    my $is_fasta = 1;
    my $line_ct  = 0;
    my $line_lim = 100; #look at the first 100 lines to make a guess
    while(<$fh>){
	chomp $_;
	my $line = $_;
	$line_ct++;
	last if( $line_ct == $line_lim );	
	next if( $line =~ m/^\>/ );
	$line = uc( $line );
	#IUPAC requirements based on this: http://www.bioinformatics.org/sms/iupac.html
	if( $type eq "nt" ){ #nucleotide check here
	    if( $line =~ m/[^ACGTURYSWKMBDHVN]/ ){
		$is_fasta = 0;
	    }
	} elsif( $type eq "aa" ){
	    if( $line =~ m/[^ACDEFGHIKLMNPQRSTVWYX]/ ){ #added X for ambigious characters
		$is_fasta = 0;
	    }	    
	} else {
	    die "I received a value for type that I don't understand (<$type>)\n";
	}
    }
    close $fh;
    if( !$is_fasta ){
	#do nothing, put control statement in main routine.
    }    
    return $is_fasta;
}


sub load_project{
    # $nseqs_per_samp_split is how many seqs should each sample split file contain?
    my ($self, $path, $nseqs_per_samp_split) = @_;    
    #get project name and load
    my ($name, $dir, $suffix) = fileparse( $path );     
    my $pid;  
    if( $self->use_db ){
	my $proj = $self->Shotmap::DB::create_project(
	    $name, 
	    $self->project_desc() 
	    );
	$pid  = $proj->project_id()
    } else {
	#for nodb runs, the pid is the name of the directory the 
	#user pointed to which contains sample sequences
	$pid = $self->Shotmap::DB::create_flat_file_project( 
	    $name, 
	    $self->project_desc() 
	    ); 
    }
    #store vars in object
    $self->project_id( $pid );
    #This has to come before load_samples
    $self->Shotmap::Run::parse_sample_metadata( $self->metadata_file );
    $self->Shotmap::DB::build_project_ffdb();
    #process the samples associated with project
    $self->Shotmap::Run::load_samples();
    $self->Shotmap::DB::build_sample_ffdb(); #this also splits the sample file
    #$self->Shotmap::Run::get_project_metadata(); we only do this at the end now
    $self->Shotmap::Notify::print_verbose(
	"Project " . $pid . 
	", with files found at <$path>, was successfully loaded!\n"
	);
}

sub get_project_metadata{
    my( $self, $output )  = @_;
    my $final_results = 0; #is this the metadata table being placed in the final output directory?
    if( defined( $output ) ){
	$final_results = 1;
    }
    if( !defined( $output ) ){
	$output   = File::Spec->catdir( $self->project_dir, "parameters", "sample_metadata.tab" );
	}
    open( OUT, ">$output" ) || die "Can't open $output for write: $!\n";
    my $data   = {}; #will push rows to data, need to know all fields before printing header
    my $fields = {};
    my $sample_hr = $self->get_sample_hashref;
    foreach my $sample_alt_id( keys( %{ $sample_hr } ) ){
	my $sample_id = $sample_hr->{$sample_alt_id}->{"id"};
	my $metadata  = $sample_hr->{$sample_alt_id}->{"metadata"};
	$data->{$sample_id}->{"alt_id"} = $sample_alt_id;
	if( !( defined( $metadata ) ) ){
	    $self->Shotmap::Notify::print( "Couldn't find input metadata for sample ${sample_alt_id}, so I'm only going to provide shotmap output statistics");
	    $fields = {};
	    next;
	    #goto PRINTMETA;
	} else {
	    my( @data )  = split( ",", $metadata );
	    foreach my $field( @data ){
		my( $field_name, $field_value ) = split( "\=", $field );
		$data->{$sample_id}->{"metadata"}->{$field_name} = $field_value;
		$fields->{$field_name}++;
	    }
	}
    }
  PRINTMETA:;
    if( defined( $fields ) ){ #then we found metadata
	#print the header
	if( $self->ags_method eq "microbecensus" ){
	    print OUT join( "\t", "Sample.Name", "Sample.ID", "Processed.Reads", "Classified.Sequences", "Total.Abundance", "Avg.Genome.Size", sort(map{ uc($_) } keys(%{$fields})), "\n" );
	} else {
	    print OUT join( "\t", "Sample.Name", "Sample.ID",  "Processed.Reads",  "Classified.Sequences", "Total.Abundance", sort(map{ uc($_) } keys(%{$fields})), "\n" );
	}
    }
    else {
	print OUT join( "\t", "Sample.Name", "Sample.ID", "\n" );
    }
    foreach my $sample_id( keys( %{ $data } ) ){
	my $row = "";
	my $sample_alt_id = $data->{$sample_id}->{"alt_id"};
	$row .= $sample_alt_id . "\t" .  $sample_id . "\t";
	if( $final_results ){ #only for final metadata file
	    $row .= $self->sample_stats( $sample_alt_id, "total_reads" )     . "\t";
	    $row .= $self->sample_stats( $sample_alt_id, "class_reads" )     . "\t";
	    $row .= $self->sample_stats( $sample_alt_id, "total_abundance" ) . "\t";
	    if( $self->ags_method eq "microbecensus" ){
		$row .= $self->sample_ags( $sample_alt_id, "ags" ) . "\t";
	    }
	    my @values = sort(keys( %{$fields} ));
	    foreach my $field( @values ){
		$row .= $data->{$sample_id}->{"metadata"}->{$field} . "\t";
	    }   
	}
	$row =~ s/\s+$//; #get rid of the final tab
	print OUT $row . "\n";	
    }
    close OUT;
    return $output;
}


sub load_samples{
    my ($self) = @_;
    my %samples = %{$self->get_sample_hashref()}; # de-reference the hash reference
    my $numSamples = scalar( keys(%samples) );
    my $plural = ($numSamples == 1) ? '' : 's'; # pluralize 'samples'
    $self->Shotmap::Notify::notify("Processing $numSamples sample${plural} associated with project " . $self->project_id() . " ");
    my $metadata = {};
    my $sid = 0; #for nodb sample creation
    #if it exists, grab each sample's metadata
    if( defined( $self->sample_metadata ) ){
	my @rows = split( "\n", $self->sample_metadata );
	my $header = shift( @rows );
	my @colnames = split( "\t", $header );
	foreach my $row( @rows ){ #all rows except the header
	    my @cols = split( "\t", $row );
	    my $samp_alt_id = $cols[0];
	    $samp_alt_id =~ s/\.fa$//; #want alt_id in this file to match that in the database.
	    $samp_alt_id =~ s/\.fna$//;
	    $samp_alt_id =~ s/\.fasta$//;
	    my $metadata_string;
	    for( my $i=1; $i < scalar(@cols); $i++){
		my $key   = $colnames[$i];
		my $value = $cols[$i]; 
		if( $i == 1 ){
		    $metadata_string = $key . "=" . $value;
		} else {
		    $metadata_string = join( ",", $metadata_string, $key . "=" . $value );
		}
	    }
	    $self->Shotmap::Notify::print_verbose( "Obtained metadata: $metadata_string\n" );
	    $metadata->{$samp_alt_id} = $metadata_string;       
	}
    }
    #load each sample
    foreach my $samp( keys( %samples ) ){
	my $pid = $self->project_id();
	my $insert;	
	my $metadata_string;
	if( defined( $self->sample_metadata ) ){
	    $metadata_string = $metadata->{$samp};
	    $samples{$samp}->{"metadata"} = $metadata_string;
	}	
	if( $self->use_db ){
	    eval { 
		$insert = $self->Shotmap::DB::create_sample($samp, $pid, $metadata_string );
	    };
	    if ($@) { # <-- this is like a "catch" block in the try/catch sense. "$@" is the exception message (a human-readable string).
		# Caught an exception! Probably create_sample complained about a duplicate entry in the database!
		my $errMsg = $@;
		chomp($errMsg);
		if ($errMsg =~ m/duplicate entry/i) {
		    print STDERR ("*" x 80 . "\n");
		    print STDERR ("DATABASE INSERTION ERROR\nCaught an exception when attempting to add sample \"$samp\" for project PID #${pid} to the database.\nThe exception message was:\n$errMsg\n");
		    print STDERR ("Note that the error above was a DUPLICATE ENTRY error.\nThis is a VERY COMMON error, and is due to the database already having a sample/project ID with the same number as the one we are attempting to insert. This most often happens if a run is interrupted---so there is an entry in the database for your project run, but there are no files on the filesystem for it, since it did not complete the run. The solution to this problem is to manually remove the entries for project id #$pid from the Mysql database. Are you sure that you want to reprocess a dataset from scratch? If so, you can remove the old data from the database via thee different options:\n");
		    print STDERR ("You can do this as follows:\n");
		    print STDERR (" Option A: Rerun your mcr_handler.pl command, but add the --reload option\n" );
		    print STDERR (" Option B: Use MySQL to remove the old data, as follows:\n" );
		    print STDERR ("   1. Go to your database server (probably " . $self->get_db_hostname() . ")\n");
		    print STDERR ("   2. Log into mysql with this command: mysql -u YOURNAME -p   <--- YOURNAME is probably \"" . $self->get_username() . "\"\n");
		    print STDERR ("   3. Type these commands in mysql: use ***THE DATABASE***;   <--- THE DATABASE is probably " . $self->get_db_name() . "\n");
		    print STDERR ("   4.                        mysql: select * from project;    <--- just to look at the projects.\n");
		    print STDERR ("   5.                        mysql: delete from project where project_id=${pid};    <-- actually deletes this project.\n");
		    print STDERR ("   6. Then you can log out of mysql and hopefully re-run this script successfully!\n");
		    print STDERR ("   7. You MAY also need to delete the entry from the 'samples' table in MySQL that has the same name as this sample/proejct.\n");
		    print STDERR ("   8. Try connecting to mysql, then typing 'select * from samples;' . You should see an OLD project ID (but with the same textual name as this one) that may be preventing you from running another analysis. Delete that id ('delete from samples where sample_id=the_bad_id;'");
		    my $mrcCleanCommand = (qq{perl \$Shotmap_LOCAL/scripts/mrc_clean_project.pl} 
					   . qq{ --pid=}    . $pid
					   . qq{ --dbuser=} . $self->get_username()
					   . qq{ --dbpass=} . "PUT_YOUR_PASSWORD_HERE"
					   . qq{ --dbhost=} . $self->get_db_hostname()
					   . qq{ --ffdb=}   . $self->ffdb()
					   . qq{ --dbname=} . $self->get_db_name()
					   . qq{ --schema=} . $self->{"schema_name"});
		    print STDERR (" Option C: Run mrc_clean_project.pl as follows:\n" );
		    print STDERR ("$mrcCleanCommand\n");
		    print STDERR ("*" x 80 . "\n");
		    die "Terminating: Duplicate database entry error! See above for a possible solution.";
		}
		die "Terminating: Database insertion error! See the message above for more details..."; # no "newline" with die!
	    }       
	    $samples{$samp}->{"id"} = $insert->sample_id();
	    my $sid                 = $insert->sample_id(); # just a short name for the sample ID above
	    if( $self->bulk_load() ){
		my $tmp    = "/tmp/" . $samp . ".sql";	    
		my $table  = "metareads";
		my $nrows  = 10000;
		my @fields = ( "sample_id", "read_alt_id", "seq" );
		my $fks    = { "sample_id" => $sid }; #foreign keys and fields not in file 
		unless( $self->is_slim() ){ 
		    $self->Shotmap::DB::bulk_import( $table, $samples{$samp}->{"path"}, $tmp, $nrows, $fks, \@fields );
		}
	    }
	    else{ 
		open( SEQS, $samples{$samp} ) || die "Can't open " . $samples{$samp} . " for read: $!\n";
		my @read_names = ();
		my $numReads   = 0;
		while(<SEQS>){
		    next unless $_ =~ m/^>/;
		    my $read    = chomp( $_ );
		    $read =~ s/^>//;    #get rid of header line description
		    $read =~ s/\s.*$//; #get rid of description
		    if( $self->is_multiload() ){
			push( @read_names, $read );
		    } else {
			$self->Shotmap::DB::create_metaread($read, $sid);
		    }
		    $numReads++;
		}		
		close SEQS;
		if( $self->is_multiload ){
		    self->Shotmap::DB::create_multi_metareads( $sid, \@read_names );
		}
		$self->Shotmap::Notify::notify("Loaded $numReads reads for sample $sid into the database.");
	    }
	} else {
	    #flatfile stuff here
	    if( $sid == 0 ){
		$sid = 1;
		#$sid = $self->Shotmap::DB::get_flatfile_sample_id( $samp );
	    } else {
		$sid++;
	    }
	    $self->Shotmap::DB::set_sample_parameters( $sid, $samp );
	    $samples{$samp}->{"id"} = $sid;
	}
    }
    $self->set_samples(\%samples);
    $self->Shotmap::Notify::notify("Successfully loaded $numSamples sample$plural associated with the project " . $self->project_id() . " ");
    return $self;
}

sub load_families{
    my( $self, $type, $db_name ) = @_;
    my $raw_db_path = undef;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }
    my $file =  "${raw_db_path}/family_lengths.tab";
    if( $self->bulk_load() ){
	my $tmp    = "/tmp/famlens.sql";	    
	my $table  = "families";
	my $nrows  = 10000;
	my @fields = ( "famid", "family_length", "family_size" );
	my $fks    = { "searchdb_id" => $self->Shotmap::DB::get_searchdb_id( $db_name, $type ) }; #foreign keys and fields not in file 
	$self->Shotmap::DB::bulk_import( $table, $file, $tmp, $nrows, $fks, \@fields );
    }
    return $self;
}

sub load_family_members{
    my( $self, $type, $db_name ) = @_;
    my $file = $self->search_db_path("blast") . "/sequence_lengths.tab";
    if( $self->bulk_load() ){
	my $tmp    = "/tmp/seqlens.sql";	    
	my $table  = "familymembers";
	my $nrows  = 10000;
	my @fields = ( "famid", "target_id", "target_length" );
	my $fks    = { "searchdb_id" => $self->Shotmap::DB::get_searchdb_id( $db_name, $type ) }; #foreign keys and fields not in file 
	$self->Shotmap::DB::bulk_import( $table, $file, $tmp, $nrows, $fks, \@fields );
    }
    return $self;
}

sub check_family_loadings{
    my( $self, $type, $db_name ) = @_;
    my $bit = 0;
    my $raw_db_path = undef;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }
    my $famlen_tab  = "${raw_db_path}/family_lengths.tab";
    my $searchdb_id = $self->Shotmap::DB::get_searchdb_id( $type, $db_name );
    my $ff_rows     = _count_lines_in_file( $famlen_tab );
    my $sql_rows    = $self->Shotmap::DB::get_families_by_searchdb_id( $searchdb_id)->count();
    $bit = 1 if( $ff_rows == $sql_rows );
    return $bit;
}

sub check_familymember_loadings{
    my( $self, $type, $db_name ) = @_;
    my $bit = 0;
    my $raw_db_path = undef;
    if ($type eq "hmm")   { $raw_db_path = $self->search_db_path("hmm"); }
    if ($type eq "blast") { $raw_db_path = $self->search_db_path("blast"); }
    my $seqlen_tab  = "${raw_db_path}/sequence_lengths.tab";
    my $searchdb_id = $self->Shotmap::DB::get_searchdb_id( $type, $db_name );
    my $ff_rows     = _count_lines_in_file( $seqlen_tab );
    my $sql_rows    = $self->Shotmap::DB::get_familymembers_by_searchdb_id( $searchdb_id)->count();
    $bit = 1 if( $ff_rows == $sql_rows );
    return $bit;
}

sub _count_lines_in_file{
    my $file = shift;
    open( FILE, $file ) || die "can't open $file for read: $!\n";
    my $count = 0;
    while( <FILE> ){
	$count++;
    }
    close FILE;
    return $count;
}

sub build_read_import_file{
    my $self      = shift;
    my $seqs      = shift;
    my $sample_id = shift;
    my $out       = shift;
    open( SEQS, "$seqs" ) || die "Can't open $seqs for read in Shotmap::Run::build_read_import_file\n";
    open( OUT,  ">$out" ) || die "Can't open $out for write in Shotmap::Run::build_read_import_file\n";
    while( <SEQS> ){
	chomp $_;
	if( $_ =~ m/^\>(.*)(\s|$)/ ){
	    my $read_alt_id = $1;
	    print OUT "$sample_id,$read_alt_id\n";
	}
    }
    return $self;
}

sub back_load_project(){
    my $self = shift;
    my $project_id = shift;
    my $ffdb = $self->ffdb();
    my $dbname = $self->db_name();
    $self->project_id( $project_id );
    if( $self->is_iso_db ){
	$self->project_dir("$ffdb/projects/$dbname/$project_id");
    } else {
	$self->project_dir("$ffdb");
    }
    $self->params_dir( $self->project_dir . "/parameters" );
    $self->params_file( $self->params_dir . "/parameters.xml" );
    if( $self->remote ){
	$self->remote_scripts_dir( $self->remote_project_path . "/scripts" ); 	
	$self->remote_project_log_dir(     $self->remote_project_path() . "/logs" );
    }
    #do some extra work for old types of jobs
    if( ! -d $self->params_dir ){
	File::Path::make_path( $self->params_dir );
    }
    if( ! -e $self->params_file ){
	$self->Shotmap::DB::initialize_parameters_file( $self->params_file );
    }
    $self->Shotmap::Run::cp_search_db_properties();
    if( defined( $self->metadata_file ) ){
	$self->Shotmap::Run::parse_sample_metadata( $self->metadata_file );
    }
}

sub cp_search_db_properties{
    my $self = shift;
    my $search_type    = $self->search_type;
    my $raw_db_path    = $self->search_db_path( $search_type ); 
    my $symlinks       = 0; #set to zero as cp gives us a single, contained directory
    my $famlen_tab     = "${raw_db_path}/" . $self->search_db_name .  "_family_lengths.tab";
    my $ffdb_famlen_cp = $self->params_dir . "/" . $self->search_db_name . "_family_lengths.tab";
    if( ! -e $famlen_tab ){
	die "Can't find family length table. Expected it here: $famlen_tab\n";
    }
    if( -e $famlen_tab && ! -e $ffdb_famlen_cp ){
	if( $symlinks ){
	    my $symlink_exists = eval { symlink( $famlen_tab, $ffdb_famlen_cp ); 1 };
	    if( ! $symlink_exists ) { #maybe symlink doesn't work on system, so let's try a cp
		copy( $famlen_tab, $ffdb_famlen_cp );
		if( ! -e $ffdb_famlen_cp){
		    die "Can't seem to create a copy of the family length table located here:\n  $famlen_tab \n".
			"Trying to place it here:\n  $ffdb_famlen_cp\n";
		}
	    }
	} else {
	    copy( $famlen_tab, $ffdb_famlen_cp );
	    if( ! -e $famlen_tab ){
		die "Can't seem to create a copy of the family length table located here:\n  $famlen_tab \n".
		    "Trying to place it here:\n  $ffdb_famlen_cp\n";
	    }
	}
    }
    my $seqlen_tab     = $self->search_db_path( $search_type ) . "/" . $self->search_db_name . "_sequence_lengths.tab";
    my $ffdb_seqlen_cp = $self->params_dir . "/" . $self->search_db_name . "_sequence_lengths.tab";
    if( ! -e $seqlen_tab && $search_type eq "blast" ){
	die "Can't find a sequence length table. Expected it here: $seqlen_tab";
    }
    if( $search_type eq "blast" && -e $seqlen_tab && ! -e $ffdb_seqlen_cp ){
	if( $symlinks ){
	    my $symlink_exists    = eval { symlink( $seqlen_tab, $ffdb_seqlen_cp); 1 };
	    if( ! $symlink_exists ) { #maybe symlink doesn't work on system, so let's try a cp
		copy( $seqlen_tab, $ffdb_seqlen_cp );
		if( ! -e $ffdb_seqlen_cp ){
		    die "Can't seem to create a copy of the family length table located here:\n  $seqlen_tab \n".
			"Trying to place it here:\n  $ffdb_seqlen_cp\n";
		}	    
	    } else {
		if( ! -l $ffdb_seqlen_cp || ! -e readlink( $ffdb_seqlen_cp ) ){
		    die "Broken symlink: $ffdb_seqlen_cp -> $seqlen_tab";
		}
	    }
	} else {
	    copy( $seqlen_tab, $ffdb_seqlen_cp );
	    if( ! -e $ffdb_seqlen_cp ){
		die "Can't seem to create a copy of the family length table located here:\n  $seqlen_tab \n".
		    "Trying to place it here:\n  $ffdb_seqlen_cp\n";
	    }	    
	}
    } else {
	if( !$search_type eq "hmm" && ! -e $ffdb_seqlen_cp ){
	    die "I couldn't find either a sequence length table. Expected ". 
		" it here:\n$seqlen_tab\n";
	}   
    }
}

#this might need extra work to get the "path" element correct foreach sample
sub back_load_samples{
    my $self = shift;
    my $project_id = $self->project_id();
    my $project_path = $self->project_dir();
    opendir( PROJ, $project_path ) || die "can't open $project_path for read: $!\n";
    my @files = readdir( PROJ );
    closedir PROJ;
    my %samples = ();
    foreach my $file( @files ){
	next if ( $file =~ m/^\./     || $file =~ m/logs/       || 
		  $file =~ m/hmmscan/ || $file =~ m/output/     || 
		  $file =~ m/\.sh/    || $file =~ m/parameters/ || 
		  $file =~ m/scripts/ 
	    );
	my $sample = $file;
	my ( $sample_id, $sample_alt_id );
	if( $self->use_db ){
	    my $samp       = $self->Shotmap::DB::get_sample_by_sample_id( $sample );
	    $sample_id     = $sample;
	    $sample_alt_id = $samp->sample_alt_id();
	} else {
	    my $samp = $self->Shotmap::DB::get_sample_by_id_flatfile( $sample );
	    $sample_id     = $samp->{"id"};
	    $sample_alt_id = $samp->{"sample_alt_id"};
	}
	#get the path to the raw sample data
	my $sample_data;
	if( -d $self->raw_data ){
	    $sample_data = glob( $self->raw_data() . "/".  $sample_alt_id . "*" );
	} else {
	    $sample_data = $self->raw_data;
	}
	$samples{$sample_alt_id}->{"path"} = $sample_data;
	$samples{$sample_alt_id}->{"id"}   = $sample_id;
    }
    $self->set_samples( \%samples );

    #back load remote data
    warn("Back-loading of samples is now complete.");
    #return $self;
}

# Note this message: "this is a compute side function. don't use db vars"
sub translate_reads {
    my ($self, $input, $output, $waitTimeInSeconds) = @_;
    my $to_split = $self->split_orfs();
    my $method   = $self->trans_method();
    my $nprocs   = $self->nprocs();
    my $bin      = $ENV{"SHOTMAP_LOCAL"} . "/bin/";
    my $length_cutoff = $self->orf_filter_length;

    (-d $input) or die "Unexpectedly, the input directory <$input> was NOT FOUND! Check to see if this directory really exists.";
    (-d $output) or die "Unexpectedly, the output directory <$output> was NOT FOUND! Check to see if this directory really exists.";
    my $inbasename  = $self->Shotmap::Run::get_file_basename_from_dir($input) . "split_"; 
    if( !defined( $inbasename ) ){
	die( "Couldn't obtain a raw file input basename to input into ${method}!");
    }
    my $outbasename = $inbasename;
    $outbasename =~ s/\_raw\_/\_orf\_/; # change "/raw/" to "/orf/"                                                                                                                      
    if( !defined( $outbasename) ){
	die( "Couldn't obtain a raw file output basename to input into ${method}!");
    }
    my( $parent, $ra_children );
    my @children = ();
    my $errors   = "";
    my $pm = Parallel::ForkManager->new($nprocs);
    $pm->run_on_finish(
	sub{ my ( $parent_id, $exit_code ) = @_;
	     if( $exit_code != 0 ){
		 die "child (parent $parent_id) returned a non-zero exit code! Got $exit_code\n";
	     }
	}
	);
    for( my $i=1; $i<=$nprocs; $i++ ){
	my $pid = $pm->start and next;
	#do some work here
	my $cmd;
        if( $method eq 'transeq' || $method eq 'transeq_split' ){
            my $infile   = "${input}/${inbasename}${i}.fa";
            my $outfile  = "${output}/${outbasename}${i}.fa";
	    if( -e "${infile}.gz" ){
		#$cmd    = "zcat ${infile}.gz | transeq -trim -frame=6 -sformat1 pearson -osformat2 pearson stdin $outfile > /dev/null 2>&1";

	    } else {
		#$cmd    = "transeq -trim -frame=6 -sformat1 pearson -osformat2 pearson $infile $outfile > /dev/null 2>&1";
	    }	    
        }
	my $infile   = "${input}/${inbasename}${i}.fa";
	my $outfile  = "${output}/${outbasename}${i}.fa";
	if( -e "${infile}.gz" ){
	    $infile = "${infile}.gz";
	}
	if( ! -e $infile ){
	    $self->Shotmap::Notify::warn( 
		"I could not find $infile for processing with translate_reads. This is not "  .
		"necessairly an error (we may have fewer input files that you expect), " .
		"but I recommend verifying"
		);
	    $pm->finish;
	}
	#ADD ADDITIONAL METHODS
        if( $method eq '6FT' ){	   
	    $cmd    = $self->python . " ${bin}/metatrans.py -m 6FT $infile $outfile";
        } 
        if( $method eq '6FT_split' ){
	    $cmd    = $self->python . " ${bin}/metatrans.py -m 6FT-split -l $length_cutoff $infile $outfile";
        } 
        if( $method eq 'prodigal' ){
	    $cmd    = $self->python . " ${bin}/metatrans.py -m Prodigal $infile $outfile";
        } 
	#execute
	$self->Shotmap::Notify::print_verbose( "$cmd\n" );
	eval{ system( $cmd ) };
	if( $@ ){
	    print( "$!\n" );
	    $errors .= "Error running $cmd: $!\n";
	    die;
	}
	$pm->finish; # Terminates the child process
    }
    $self->Shotmap::Notify::print( "\tWaiting for all local jobs to finish...\n" );
    $pm->wait_all_children;
    #old code, no longer using, replaced with Parallel::Fork
    if( 0 ){
      TRANSLATEFORK: for( my $i=1; $i<=$nprocs; $i++ ){
	  my $cmd;
	  if( $method eq 'transeq' || $method eq 'transeq_split' ){	
	      my $infile   = "${input}/${inbasename}${i}.fa";
	      my $outfile  = "${output}/${outbasename}${i}.fa";
	      $cmd      = "transeq -trim -frame=6 -sformat1 pearson -osformat2 pearson $infile $outfile > /dev/null 2>&1";
	      $self->Shotmap::Notify::print_verbose( "$cmd\n" );
	  }
	  #ADD ADDITIONAL METHODS HERE
	  
	  #SPAWN THREADS
	  ( $parent, $ra_children ) = $self->Shotmap::Run::spawn_local_threads( $cmd, "translate", \@children );
	  @children = @{ $ra_children };
        }
	$self->Shotmap::Run::destroy_spawned_threads( $parent, \@children );
    }
    $self->Shotmap::Notify::print( "\t...metatrans (${method}) has finished. Proceeding");
    return $self;
}

sub split_orfs_local{
    my ($self, $input, $output) = @_;
    my $splitscript   = File::Spec->catfile( $self->local_scripts_dir, "remote/split_orf_on_stops.pl" );
    my $length_cutoff = $self->orf_filter_length;
    my $nprocs   = $self->nprocs();
    (-d $input) or die "Unexpectedly, the input directory <$input> was NOT FOUND! Check to see if this directory really exists.";
    (-d $output) or die "Unexpectedly, the output directory <$output> was NOT FOUND! Check to see if this directory really exists.";
    my $inbasename  = $self->Shotmap::Run::get_file_basename_from_dir($input) . "split_";  
    if( !defined( $inbasename ) ){
	die( "Couldn't obtain a raw file input basename to input into ${splitscript}!");
    }
    my $outbasename = $inbasename;
    if( !defined( $outbasename) ){
	die( "Couldn't obtain a raw file output basename to input into ${splitscript}!");
    }
    my $pm = Parallel::ForkManager->new($nprocs);
    $pm->run_on_finish(
	sub{ my ( $parent_id, $exit_code ) = @_;
	     if( $exit_code != 0 ){
		 die "child (parent $parent_id) returned a non-zero exit code! Got $exit_code\n";
	     }
	}
	);
    for( my $i=1; $i<=$nprocs; $i++ ){
        my $pid = $pm->start and next;
	#do some work here
	my $cmd;
	my $infile   = "${input}/${inbasename}${i}.fa";
	my $outfile  = "${output}/${outbasename}${i}.fa";
	$cmd      = "perl $splitscript -l $length_cutoff -i $infile -o $outfile > /dev/null 2>&1";	
	my $results = IPC::System::Simple::capture("$cmd");
        (0 == $EXITVAL) or die("Error executing this command:\n${cmd}\nGot these results:\n${results}\n");
        #system( $cmd );
        $pm->finish; # Terminates the child process                                                                                                                                                                                          
    }
    $self->Shotmap::Notify::print( "\tWaiting for local jobs to finish...\n" );
    $pm->wait_all_children;
    #old code, now obsolete
    if( 0 ){
      SPLITFORK: for( my $i=1; $i<=$nprocs; $i++ ){
	  my $cmd;
	  my $infile   = "${input}/${inbasename}${i}.fa";
	  my $outfile  = "${output}/${outbasename}${i}.fa";
	  $cmd      = "perl $splitscript -l $length_cutoff -i $infile -o $outfile > /dev/null 2>&1";
	  #SPAWN THREADS
	  $self->Shotmap::Run::spawn_local_threads( $cmd, "split_orfs" );
      }
    }
    $self->Shotmap::Notify::print( "\t...finished splitting orfs. Proceeding\n");
    return $self;

}

sub get_file_basename_from_dir($$){
    my( $self, $input ) = @_; #input is directory
    my $inbasename;
    my $outbasename;
    (-d $input) or die "Unexpectedly, the input directory <$input> was NOT FOUND! Check to see if this directory really exists.";
    opendir( IN, $input ) || die "Can't opendir $input for read: $!";
    my @infiles = readdir(IN);
    closedir( IN );
    if(!defined($inbasename)) { #let's set some vars, but we won't process until we've looped over the entire directory                                                                      
	foreach my $file( @infiles ){
	    next if ($file =~ m/^\./ ); # Skip any files starting with a dot, including the special ones: "." and ".."
	    ($file =~ m/^(.*?)split\_*/) or die "Can't grab the new basename from the file <$file>!";
	    $inbasename  = $1;
	}
    }
    if( !defined( $inbasename ) ){
	die( "Couldn't obtain a raw file input basename from ${input}!");
    }
    return $inbasename;
}

#This and destroy_spawned_threads are close to working, but not quite right: parent doesn't seem to 
#appropriately wait for child processes. 
sub spawn_local_threads($$$){
    my( $self, $cmd, $type, $ra_children, $outfile ) = @_; #we use outfile to check if we need to rerun anything
    #for more on forks, see http://www.resoo.org/docs/perl/perl_tutorial/lesson12.html
    my $pid = $$;
    my $parent = 0;
    my @children = @{ $ra_children };
    
    my $newpid  = fork();
    if( !defined( $newpid ) ){ #this shouldn't happen...
	die "fork didn't work: $!\n";
    } elsif( $newpid == 0 ) {
	# if return value is 0, this is the child process
	$parent   = $pid; # which has a parent called $pid
	$pid      = $$;   # and which will have a process ID of its very own
	@children = ();   # the child doesn't want this baggage from the parent
	if( defined( $outfile ) ){
	    if( $type eq "search" && -e $outfile && !($self->force_search) ){
		warn( "I found results at $outfile. I will not overwrite them without the --forcesearch option!\n");
		next;
	    }	    
	    if( $type eq "parse" && -e $outfile && !($self->force_parse) ){
		warn( "I found results at $outfile. I will not overwrite them without the --forceparse option!\n");
		next;
	    }	    
	}
	open STDERR, ">&=", \*STDOUT or print "$0: dup: $!";
	$self->Shotmap::Notify::print_verbose( "About to run the following command:\n${cmd}" );
	exec($cmd) or die ("Couldn't exec $cmd: $!");
	sleep(10);
	exit( 0 );
	if( $type eq "translate" ){
	    last TRANSLATEFORK;      # and we don't want the child making babies either
	} elsif( $type eq "split_orfs" ){
	    last SPLITFORK;
	} elsif( $type eq "search" ){
	    last SEARCHFORK;
	} elsif( $type eq "parse" ){
	    last PARSEFORK;
	}	
    } else{
	push( @children, $newpid );
    }
    return ( $parent, \@children );
}

sub destroy_spawned_threads{ 
    my ( $self, $pid, $ra_children ) = @_;
    my @children = @{ $ra_children };
    
    if( $pid == 0 ){ # if I have a parent, i.e. if I'm the child process
	#could optionally do something here
	exit( 0 );
    } else {
	# parent process needs to preside over the death of its kids
	while ( my $child = shift @children ) {
	    print "Parent waiting for thread with pid $child to die\n";
	    my $reaped = waitpid( $child, 0 );
	    unless ( $reaped == $child ){
		print "Something went wrong with our child $child: $?\n";
	    }
	}
    }
}

sub load_multi_orfs{
    my ($self, $orfsBioSeqObject, $sample_id, $algo) = @_;   # $orfsBioSeqObject is a Bio::Seq object
    my %orfHash       = (); #orf_alt_id to read_id
    my %readHash      = (); #read_alt_id to read_id
    my $numOrfsLoaded = 0;
    while (my $orf = $orfsBioSeqObject->next_seq() ){
	my $orf_alt_id  = $orf->display_id();
	my $read_alt_id = $self->Shotmap::Run::parse_orf_id( $orf_alt_id, $algo );
	#get the read id, but only if we haven't see this read before
	my $read_id = undef;
	if(defined($readHash{$read_alt_id} ) ){
	    $read_id = $readHash{$read_alt_id};
	} else{
	    my $reads = $self->get_schema->resultset("Metaread")->search( { read_alt_id => $read_alt_id, sample_id   => $sample_id } ); # "search" takes some kind of anonymous hash or whatever this { } thing is
	    if ($reads->count() > 1) { die("Found multiple reads that match read_alt_id: $read_alt_id and sample_id: $sample_id in load_orf. Cannot continue!"); }
	    my $read = $reads->next();
	    $read_id = $read->read_id();
	    $readHash{ $read_alt_id } = $read_id;
	}
	$orfHash{ $orf_alt_id } = $read_id;
	$numOrfsLoaded++;
    }
    $self->Shotmap::DB::insert_multi_orfs( $sample_id, \%orfHash );
    $self->Shotmap::Notify::notify("Bulk loaded a total of <$numOrfsLoaded> orfs to the database.");
    ($numOrfsLoaded > 0) or die "Uh oh, we somehow were not able to load ANY orfs in the Run.pm function load_multi_orfs. Sample ID was <$sample_id>. Maybe this is because you didn't --stage the database? Really unclear.";
}

sub bulk_load_orf{
    my $self    = shift;
    my $seqfile = shift;
    my $sid     = shift;
    my $method  = shift;
    my $tmp    = "/tmp/" . $sid . ".sql";	    
    my $table  = "orfs";
    my $nrows  = 10000;
    my @fields = ( "sample_id", "read_alt_id" );
    my $fks    = { "sample_id" => $sid,
		   "method" => $method,
                 }; 
    $self->Shotmap::DB::bulk_import( $table, $seqfile, $tmp, $nrows, $fks, \@fields );
    return $self;
}

sub read_alt_id_to_read_id{
    my $self        = shift;
    my $read_alt_id = shift;
    my $sample_id   = shift;
    my $read_map    = shift; #hashref
    my $read_id;
    if( defined( $read_map->{ $read_alt_id } ) ){
	$read_id = $read_map->{ $read_alt_id };
    }
    else{
	my $reads = $self->get_schema->resultset("Metaread")->search(
	    {
		read_alt_id => $read_alt_id,
		sample_id   => $sample_id,
	    }
	    );
	if( $reads->count() > 1 ){
	    warn "Found multiple reads that match read_alt_id: $read_alt_id and sample_id: $sample_id in load_orf. Cannot continue!\n";
	    die;
	}
	my $read = $reads->next();
	$read_id = $read->read_id();
    }
    return $read_id;
}

sub parse_orf_id{
    my $self   = shift;
    my $orfid  = shift;
    my $method = shift;
    my $read_id = ();
    if( $method eq "transeq" ){
	if( $orfid =~ m/^(.*?)\_\d$/ ){
	    $read_id = $1;
	}
	else{
	    die "Can't parse read_id from $orfid\n";
	}
    }
    if( $method eq "transeq_split" ){
	if( $orfid =~ m/^(.*?)\_\d_\d+$/ ){
	    $read_id = $1;
	}
	else{
	    die "Can't parse read_id from $orfid\n";
	}
    }
    return $read_id;
}

sub parse_and_load_search_results_bulk{
    my $self                = shift;
    my $sample_id           = shift;
    my $orf_split_filename  = shift; # just the file name of the split, NOT the full path
    my $class_id            = shift; #the classification_id
    my $algo                = shift;
    my $top_type            = $self->top_hit_type; #best_hit or best_in_fam

    ($orf_split_filename !~ /\//) or die "The orf split FILENAME had a slash in it (it was \"$orf_split_filename\"). But this is only allowed to be a FILENAME, not a directory! Fix this programming error.\n";

    #remember, each orf_split has its own search_results sub directory
    my $search_results = File::Spec->catfile($self->get_sample_path($sample_id), "search_results", $algo, $orf_split_filename);
    my $query_seqs     = File::Spec->catfile($self->get_sample_path($sample_id), "orfs", $orf_split_filename);
    #open search results, get all results for this split
    #Optionally load the data into the searchresults table
    if( $self->use_db ){
	unless( $self->is_slim ){
	    $self->Shotmap::Notify::print_verbose( "Loading results for sample ${sample_id} into database\n");
	    opendir( RES, $search_results ) || die "Can't open $search_results for read in parse_and_load_search_results_bulk: $!\n";
	    my @result_files = readdir( RES );
	    closedir( RES );
	    foreach my $result_file( @result_files ){
		next if( $result_file !~ m/\.mysqld/ ); 
		$result_file = $search_results . "/${result_file}";
		if( 1 ){ #we REQUIRE this type lof loading now
		    my $tmp    = "/tmp/" . $sample_id . ".sql";	    
		    my $table  = "searchresults";
		    my $nrows  = 10000;
		    my @fields = ( "orf_alt_id", "read_alt_id", "sample_id", "target_id", "famid", "score", "evalue", "orf_coverage", "aln_length", "classification_id" );
		    my $fks    = { "sample_id"         => $sample_id, 
				   "classification_id" => $class_id,
		    };	   #do we need this? seems safer, and easier to insert, remove samples/classifications from table this way, but also a little slower with extra key check. those tables are small.
		    $self->Shotmap::DB::bulk_import( $table, $result_file, $tmp, $nrows, $fks, \@fields );    
		}
	    }
	}
    }
    return $self;
}

sub parse_and_load_search_results_bulk_obsolete{
    my $self                = shift;
    my $sample_id           = shift;
    my $orf_split_filename  = shift; # just the file name of the split, NOT the full path
    my $class_id            = shift; #the classification_id
    my $algo                = shift;
    my $top_type            = $self->top_hit_type; #best_hit or best_in_fam

    ($orf_split_filename !~ /\//) or die "The orf split FILENAME had a slash in it (it was \"$orf_split_filename\"). But this is only allowed to be a FILENAME, not a directory! Fix this programming error.\n";

    #remember, each orf_split has its own search_results sub directory
    my $search_results = File::Spec->catfile($self->get_sample_path($sample_id), "search_results", $algo, $orf_split_filename);
    my $query_seqs     = File::Spec->catfile($self->get_sample_path($sample_id), "orfs", $orf_split_filename);
    my $output_file    = $search_results . ".mysqld.splitcat";    
    $self->Shotmap::Notify::print_verbose( "Grabbing results for sample ${sample_id} from ${search_results}\n");
    #open search results, get all results for this split
    $self->Shotmap::Run::classify_mysqld_results_from_dir( $search_results, $output_file, $orf_split_filename, $top_type );
    #Optionally load the data into the searchresults table
    if( $self->use_db ){
	unless( $self->is_slim ){
	    $self->Shotmap::Notify::print_verbose( "Loading results for sample ${sample_id} into database\n");
	    if( 1 ){ #we REQUIRE this type lof loading now
		my $tmp    = "/tmp/" . $sample_id . ".sql";	    
		my $table  = "searchresults";
		my $nrows  = 10000;
		my @fields = ( "orf_alt_id", "read_alt_id", "sample_id", "target_id", "famid", "score", "evalue", "orf_coverage", "aln_length", "classification_id" );
		my $fks    = { "sample_id"         => $sample_id, 
			       "classification_id" => $class_id,
		};	   #do we need this? seems safer, and easier to insert, remove samples/classifications from table this way, but also a little slower with extra key check. those tables are small.
		$self->Shotmap::DB::bulk_import( $table, $output_file, $tmp, $nrows, $fks, \@fields );    
	    }
	}
    }
    return $self;
}

#used to be parse_mysqld_results_from_dir
sub classify_mysqld_results_from_dir{
    my ( $self, $results_dir, $output_file, $file_string_to_match, $top_type, $recurse ) = @_; #top_type is "best_hit" or "best_in_fam"
    my $class_level = $self->class_level;
    opendir( RES, $results_dir ) || die "Can't open $results_dir for read in parse_and_load_search_results_bulk: $!\n";
    my @result_files = readdir( RES );
    closedir( RES );
    my $touched = 0; #have we init output file during this run?
    PARSELOOP: foreach my $result_file( @result_files ){
	#testing purposes only...
	#next if ( $result_file =~ m/\.splitcat/ );
	#each resultfile contains unique orfs, so process one at a time 
	my $tophits = {};
	next if ( $result_file =~ m/^\./ );
	next if ( $result_file =~ m/splitcat/ ); #we have now eliminated the need for these files, skip them if processing an old run
	#we need to enable recurision here (single level) for local runs so that we can get to the parse search results       
	if( defined( $recurse) && -d "${results_dir}/${result_file}" ){ 
	    opendir( RECURSE, "${results_dir}/${result_file}" ) || die "Can't open ${results_dir}/${result_file} for readdir: $!\n";
	    my @recurse_files = readdir RECURSE;
	    closedir RECURSE;
	    #Here, we have to look across all db-split-result-files for an orf-split
	    foreach my $recurse_file( @recurse_files ){
		next if ( $recurse_file !~ m/\.mysqld/ );
		my $db_name = $self->search_db_name;
		if ( $recurse_file !~ m/$db_name/ ){ #probably only for --iterate-output runs; make sure we only parse this run's results
		    #print "passing $recurse_file\n";
		    next;
		} 
		$self->Shotmap::Notify::print_verbose( "processing: $recurse_file\n" );
		if( $top_type eq "best_in_fam" ){
		    if( $class_level eq "orf" ){
			$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}/${recurse_file}", $tophits ) };
		    } elsif( $class_level eq "read" ){
			$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}/${recurse_file}", $tophits ) }; 
		    } else {
			die "I received a class level that I don't know how to process <${class_level}>\n";
		    }
		} elsif( $top_type eq "best_hit" ){
		    #we have to look across all result files in this dir and for each orf to fam mapping, grab the top scoring hit
		    if( $class_level eq "orf" ){
			$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}/${recurse_file}", $tophits ) };
		    } elsif( $class_level eq "read" ){
			$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}/${recurse_file}", $tophits ) };
		    } else {
			die "I received a class level that I don't know how to process <${class_level}>\n";
		    }
		}
	    }
	}
	if( $result_file !~ m/\.mysqld/ ){
	    next unless( defined( $recurse) && -d "${results_dir}/${result_file}" ); 
	}
	$self->Shotmap::Notify::print_verbose( "processing: $result_file\n" );
	if(not( $result_file =~ m/$file_string_to_match/ )) {
	    unless( defined( $recurse) && -d "${results_dir}/${result_file}" ){
		warn "Skipped the file $result_file, as it did not match the name: $file_string_to_match.";
		next; ## skip it!
	    }
	}
	#we have to look across all result files in this dir and for each orf to fam mapping, grab the top scoring hit
	#only if we want expanded search result ouput. Probably rare
	if( $top_type eq "best_in_fam" ){	   
	    if( $class_level eq "orf" ){
		$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}", $tophits ) }; 
	    } elsif( $class_level eq "read" ){
		$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}", $tophits ) };
	    } else {
		die "I received a class level that I don't know how to process <${class_level}>\n";
	    }
	} elsif( $top_type eq "best_hit" ){
	    #we have to look across all result files in this dir and for each orf to fam mapping, grab the top scoring hit	   
	    if( $class_level eq "orf" ){
		$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}", $tophits ) };
	    } elsif( $class_level eq "read" ){
		$tophits = ${ $self->Shotmap::Run::find_tophit( "${results_dir}/${result_file}", $tophits )};
	    } else {
		die "I received a class level that I don't know how to process <${class_level}>\n";
	    }       
	} else {
	    die "I don't know how to deal with the top hit type value of <${top_type}>\n";
	}
	#let's write this orf-split's results to file
	my $fh;
	if( ! $touched ){
	    open( $fh, ">$output_file" ) || die "Can't open $output_file for write: $!\n";
	    $touched = 1;
	} else {
	    open( $fh, ">>$output_file" ) || die "Can't open $output_file for write: $!\n";
	}	    
	if( !defined( $tophits ) ){
	    $self->Shotmap::Notify::warn( "No results were obtained while parsing $results_dir!\n" );
	}
	foreach my $key( keys( %$tophits ) ){      
	    if( $top_type eq "best_in_fam" ){
		foreach my $fam( keys( %{ $tophits->{$key} } ) ){
		    print $fh $tophits->{$key}->{$fam} . "\n";
		}
	    } elsif( $top_type eq "best_hit" ){
		print $fh $tophits->{$key} . "\n";
	    }
	}
	$tophits = {};
	close $fh;
    }
    return $self;
}

sub find_tophit{ #for each orf to family mapping, find the top hit
    my( $self, $result_file, $tophit ) = @_; #tophit is a hashref
    my $hit_type = $self->top_hit_type;
    my $level    = $self->class_level;
    my $res_fh;
    if( $result_file =~ m/\.gz/ ){
	open( $res_fh, "zcat $result_file|" ) || die "Can't open $result_file for read: $!\n";
    } else {
	open( $res_fh, $result_file ) || die "Can't open $result_file for read: $!\n";
    }
    while(<$res_fh>){
	chomp $_;
	my( $read, $orf, $famid, $score, $evalue, $coverage, $readlen );
	if( $_ =~ m/(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)/ ){
	    $orf      = $1;
	    $read     = $2;
	    $famid    = $5;
	    $score    = $6;
	    $evalue   = $7;
	    $coverage = $8;
	    if( $orf =~ m/\-rl(\d+?)\_/ ){
		$readlen = $1;
	    } else {
		die( "Can't parse read length from $orf\n" );
	    }
	} else {
	   warn( "Can't parse orf_alt_id, famid, or score from $result_file where line is $_\n" );
	   next;
	}
	if ( ! $self->Shotmap::Run::check_passing_hit( $readlen, $score, $evalue, $coverage ) ){	    
	    next;
	}
	if( $hit_type eq "best_hit" && $level eq "orf" ){
	    if( !defined($tophit->{$orf} ) ){
		$tophit->{$orf} = $_;
	    }
	    elsif( $score == _get_score_from_mysqld_row( $tophit->{$orf} ) ){
		my @a = ( 0, 1 );
		my $pick = $a[ rand @a ];
		if( $pick == 0 ){
		    #do nothing - the old hit wins the tie
		} else {
		    $tophit->{$orf} = $_;
		}
	    }
	    elsif( $score > _get_score_from_mysqld_row( $tophit->{$orf} ) ){
		$tophit->{$orf} = $_;
	    }
	    else{
		#do nothing. this is a poorer hit than what we already have
	    }
	} elsif ( $hit_type eq "best_in_fam" && $level eq "orf" ){
	    if( !defined($tophit->{$orf}->{$famid} ) ){
		$tophit->{$orf}->{$famid} = $_;
	    }
	    elsif( $score > _get_score_from_mysqld_row( $tophit->{$orf}->{$famid} ) ){
		$tophit->{$orf}->{$famid} = $_;
	    }
	    else{
		#do nothing. this is a poorer hit than what we already have
	    }
	} elsif ( $hit_type eq "best_hit" && $level eq "read" ){
	    if( !defined( $tophit->{$read} ) ){
		$tophit->{$read} = $_;
	    }
	    elsif( $score > _get_score_from_mysqld_row( $tophit->{$read} ) ){
		$tophit->{$read} = $_;
	    }
	    else{
		#do nothing. this is a poorer hit than what we already have
	    }
	} elsif( $hit_type eq "best_in_fam" && $level eq "read" ){
	    if( !defined($tophit->{$read}->{$famid} ) ){
		$tophit->{$read}->{$famid} = $_;
	    }
	    elsif( $score > _get_score_from_mysqld_row( $tophit->{$read}->{$famid} ) ){
		$tophit->{$read}->{$famid} = $_;
	    }
	    else{
		#do nothing. this is a poorer hit than what we already have
	    }
	} else{
	    die "I don't know how to find a top hit using parameters " .
		"hit_type = <${hit_type}> && class_level = <${level}>\n";
	}
    }
    close $res_fh;
    return \$tophit;
}

sub check_passing_hit{
    my( $self, $length, $score, $evalue, $coverage ) = @_;
    my $pass = 1;
    if( $self->adapt_class ){
	my $threshold = $self->Shotmap::Run::get_length_based_cutoff_score( $length );
	if( $score < $threshold ){
	    $pass = 0;
	}
    } else {
	if( defined( $self->class_evalue ) ){
	    if( $evalue > $self->class_evalue ){
		$pass = 0;
	    }
	    #print join( "\t", $evalue, $self->class_evalue, $pass, "\n" );
	}
	if( defined( $self->class_coverage ) ){
	    if( $coverage < $self->class_coverage ){
		$pass = 0;
	    }
	}
	if( defined( $self->class_score ) ){
	    if( $score < $self->class_score ){
		$pass = 0;
	    }
	}   
    }
    return $pass;
}

sub _get_score_from_mysqld_row{
    my ( $row ) = @_;
    my $score;
    if( $row =~ m/(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)\,(.*?)/ ){
	$score  = $6;
    }
    if( !defined( $score ) ){
	die "Could parse score from the following mysqld row:\n$row\n";
    }
    return $score;
}

sub _parse_famid_from_ffdb_seqid {
    my $hit = shift;
    my $famid;
    if( $hit =~ m/^(.*?)\_(\d+)$/ ){
	$famid = $2;
    }
    else{
	warn( "Can't parse famid from $hit in _parse_famid_from_ffdb_seqid!\n" );
	die;
    }
    return $famid;
}

#NOTE: If running a local process, then the split size isn't used, and
#single large db is created.
sub build_search_db{
    my $self        = shift;
    my $db_name     = shift; #name of db to use, if build, new db will be named this. check for dups
    my $force       = shift; #0/1 - force overwrite of old DB during compression.
    my $type        = shift; #blast/hmm
    my $reps_only   = shift; #0/1 - should we only use representative sequences in our sequence DB
    my $nr_db       = shift; #0/1 - should we use a non-redundant version of the DB (sequence DB only)

    my $ffdb        = $self->ffdb();
    my $ref_ffdb    = $self->ref_ffdb();

    #get some db properties
    #where is the hmmdb going to go? each hmmdb has its own dir
    my $raw_db_path = undef;
    my $split_size  = undef; #only used if a remote process and then only optionally
    my $length      = 0;
    if ($type eq "hmm") { 
	$raw_db_path = $self->search_db_path("hmm"); 
	if( defined( $self->search_db_split_size("hmm") ) ){	    
	    $split_size = $self->search_db_split_size("hmm");
	}
    }
    if ($type eq "blast") { 
	$raw_db_path = $self->search_db_path("blast"); 
	if( defined( $self->search_db_split_size("blast") ) ){
	    $split_size = $self->search_db_split_size("blast");
	}
    }
    if( defined( $self->search_db_split_size($type) ) ){
	$self->Shotmap::Notify::notify_verbose( "Building $type DB $db_name, placing $split_size per split\n" );
    } else {
	$self->Shotmap::Notify::notify_verbose( "Bulding $type DB $db_name, this will be a single file\n" );
    }
    #if( $self->is_iso_db ){
	#$raw_db_path = File::Spec->catdir($raw_db_path, $self->search_db_name( $type ) );
    #}
    (defined( $raw_db_path ) ) || die "Wasn't able to calculate the location to place the database";
    #Have you built this DB already?[
    if( -d $raw_db_path && !($force) ){
	die "You've already built a <$type> database with the name <$db_name> at <$raw_db_path>. Please delete or overwrite by using the --force-searchdb option.\n";
    } elsif( -d $raw_db_path && $force ){
	rmtree( $raw_db_path );
	mkdir( $raw_db_path );
    } else {
	mkdir( $raw_db_path );
    }

    #create the HMMdb dir that will hold our split hmmdbs
    #$self->Shotmap::DB::build_db_ffdb( $raw_db_path );
    #update the path to make it easier to build the split hmmdbs (e.g., points to an incomplete file name)
    #save the raw path for the database_length file when using blast

    my $db_path_with_name= "${raw_db_path}/${db_name}";
#    if( $self->is_iso_db ){
#	$db_path_with_name = $raw_db_path;
#    } else {
#	$db_path_with_name = "$raw_db_path/$db_name";
#    }
    #get the paths associated with each family
    $self->Shotmap::Notify::print_verbose( "Building family reference path hash" );
    my $family_path_hashref = $self->Shotmap::Run::build_family_ref_path_hash( $ref_ffdb, $type );
    $self->Shotmap::Notify::print_verbose( "Done!" );
    #constrain analysis to a set of families of interest
    my @families = ();
    if( defined( $self->family_subset() ) ){
	@families = sort( @{ $self->family_subset() });
    } else {
	@families = keys( %{ $family_path_hashref->{$type} } );
    } 
    my $n_fams = @families;
    my $count      = 0;
    my @split      = (); #array of family HMMs/sequences (compressed)
    my $n_proc     = 0;
    #type eq blast specific vars follow
    my $tmp;
    my $tmp_path;
    my $total = 0;
    my $seqs  = {};
    my $id    = ();
    my $seq   = '';	   
    my $redunts;
    #build a map of family lengths    
    my $family_length_file = "${raw_db_path}/" . $self->search_db_name . "_family_lengths.tab"; 
    my $seq_length_file    = "${raw_db_path}/" . $self->search_db_name . "_sequence_lengths.tab";
    $self->Shotmap::Notify::print_verbose( "Initializing family length file here: $family_length_file" );
    open( FAMLENS, ">$family_length_file" ) || die "Can't open $family_length_file for write: $!\n";
    #build a map of family member sequence lengths, not relevant for type = hmm
    $self->Shotmap::Notify::print_verbose( "Initializing sequence length file here: $seq_length_file" );
    open( SEQLENS, ">$seq_length_file" ) || die "Can't open $seq_length_file for write:$!\n";
    #blast requires tmp files for creation of NR database
    if( $type eq "blast" ){
	$tmp_path = "${db_path_with_name}.tmp";
	open( TMP, ">$tmp_path" ) || die "Can't open $tmp_path for write: $!\n";
	$tmp = *TMP;	    
	#need a home to list redundant sequence mappings if $nr_db
	if( $nr_db ){
	    my $redunt_path = "${raw_db_path}/redundant_sequence_pairings.tab";
	    open( REDUNTS, ">${redunt_path}" ) || die "Can't open ${redunt_path} for write:$!\n";
	    $redunts = *REDUNTS;
	}
    }       
    $self->Shotmap::Notify::print_verbose( "Processing families..." );
    foreach my $family( @families ){
	#find the HMM/sequences associated with the family (compressed)
	my $family_db_file = undef;
	my $family_length  = undef;
	if ($type eq "hmm") {
#	    my $path = "${ref_ffdb}/HMMs/${family}.hmm.gz";
	    my $path = $family_path_hashref->{$type}->{$family};
	    if( -e $path ) { $family_db_file = $path; } # assign the family_db_file to this path ONLY IF IT EXISTS!
	    $family_length = _get_family_length( $family_db_file, $type ); #get the family length from the HMM file
	    print FAMLENS join( "\t", $family, $family_length, "\n" );
	    (defined($family_db_file)) or die("Can't find the HMM corresponding to family $family\n" );
	    push( @split, $family_db_file );
	    $count++;
	    #if we've hit our split size, process the split
	    if( defined( $self->search_db_split_size("hmm") ) ){
		if( ( defined( $split_size ) && $count >= $split_size ) || $family eq $families[-1]) {
		    $n_proc++; 	    #build the DB
		    my $split_db_path;
		    $split_db_path = $self->Shotmap::Run::cat_db_split(
			$db_path_with_name, $n_proc, $ffdb, ".hmm", \@split, $type, 0
			); # note: the $nr_db parameter for hmm is ALWAYS zero --- it makes no sense to build a NR HMM DB
		    gzip_file($split_db_path); # We want DBs to be gzipped.
		    unlink($split_db_path); # So we save the gzipped copy, and DELETE the uncompressed copy
		    @split = (); # clear this out
		    $count = 0; # clear this too
		}
	    } else {
		#this is a local procedure and we only want a single, large db
		if( $family eq $families[-1] ) {
                    $n_proc++;      
		    my $split_db_path;
		    $split_db_path = $self->Shotmap::Run::cat_db_split(
			$db_path_with_name, $n_proc, $ffdb, ".hmm", \@split, $type, 0
			); # note: the $nr_db parameter for hmm is ALWAYS zero --- it makes no sense to build a NR HMM DB
                    gzip_file($split_db_path); 
                    unlink($split_db_path); 
                    @split = (); 
                    $count = 0; 
		}	    
	    }
	} elsif( $type eq "blast" ) {
	    my $path = $family_path_hashref->{$type}->{$family};	    
	    if( -e $path ){
		$family_db_file = $path; # <-- save the path, if it exists
	    }
	    (defined($family_db_file)) or die( "Can't find the BLAST database corresponding to family $family\n" );
	    $self->Shotmap::Notify::print_verbose( "...working on $family_db_file" );
	    #process the families and produce split dbs along the way
	    my $compressed = 0; #auto detect if ref-ffdb family files are compressed or not
	    if( $family_db_file =~ m/\.gz$/ ){
		$compressed = 1;
	    }
	    my $suffix = ''; #determine the suffix of the family file
	    if( $family_db_file =~ m/\.faa$/ || $family_db_file =~ /\.faa\.gz$/ ){
		$suffix = ".faa";
	    } elsif( $family_db_file =~ m/\.fa$/ || $family_db_file =~ /\.fa\.gz$/ ){
		$suffix = ".fa";
	    } elsif( $family_db_file =~ m/\.fasta$/ || $family_db_file =~ /\.fasta\.gz$/ ){
		$suffix = ".fasta";
	    } elsif( $family_db_file =~ m/\.pep$/ || $family_db_file =~ /\.pep\.gz$/ ){
		$suffix = ".pep";
	    } elsif( $family_db_file =~ m/\.aa$/ || $family_db_file =~ /\.aa\.gz$/ ){
		$suffix = ".aa";
	    }
	    else {
		$self->Shotmap::Notify::warn("This doesn't appear to be a fasta file: $family_db_file. Skipping.\n" );
		next;
	    }	   
	    if( $nr_db ){
		$self->Shotmap::Notify::print_verbose( "...making nonredundant" );
		my $nr_tmp      = $self->Shotmap::Run::build_nr_seq_db( $family_db_file, $suffix, $self->tmp_dir, $compressed, $redunts );
		$family_db_file = $nr_tmp;
	    }
	    $self->Shotmap::Notify::print_verbose( "...in file" );	    
	    open( FILE, "zcat --force $family_db_file |") # zcat --force can TRANSPARENTLY read both .gz and non-gzipped files!
		|| die "Unable to open the file \"$family_db_file\" for reading: $! --"; 
	    my $fam_init_len = $length; #used to calculate $family_length
	    my $fam_nseqs    = 0; #used to calculate $family_length	    
	    my $seq_len      = 0;
	    while(<FILE>){
		#we have to do a greedy search for the seqid in case the header contains annotation, as rapsearch truncates to just seqid
		if ( $_ =~ m/^\>(.*?)\s/ ){ 
		    my $temporary = $1; #holds the seqid, drop into $id after checking if old $id is defined
		    $total++;
		    $fam_nseqs++;
		    #no longer need _append_famids_to_seqids, we just do it here now
		    chomp $_;
		    if( defined( $id ) ){ #then we've seen a seq before, add that one to the hash
			$seqs->{$id} = $seq; #build an amended id to sequence hash for batch printing (below)
			$id =~ s/\>//; #get rid of fasta header indicator for our SEQLENS lookup map
			chomp( $id );
			print SEQLENS join( "\t", $family, $id, $seq_len, "\n" );
			$id  = ();
			$seq = '';
			$seq_len = 0;
		    }
		    if( $nr_db ){ #we cat famid to id in _build_nr_seq_db
			$id = ">" . $temporary . "\n";
		    } else {
			$id = ">" . $temporary . "_" . $family . "\n"; #note that this may break families that have more than seqid on the header line
		    }
		} else{
		    chomp $_; # remove the newline
		    $length += length($_);
		    $seq    .= $_ . "\n";
		    $seq_len += length($_);
		}
		if( eof ){ #end of file could be the current line or the next line (empty), so separate it from the main conditional statement
		    $seqs->{$id} = $seq; #build an amended id to sequence hash for batch printing (below)
		    $id =~ s/\>//; #get rid of fasta header indicator for our SEQLENS lookup map
		    chomp( $id );
		    print SEQLENS join( "\t", $family, $id, $seq_len, "\n" );
		    $id  = ();
		    $seq = '';
		    $seq_len = 0;		
		}
		if( defined( $self->search_db_split_size( "blast" ) ) ){
		    #we've hit our desired size (or at the end). Process the split		    
		    if( ( defined( $split_size) && ( scalar( keys( %$seqs ) ) >= $split_size ) ) || ( $family eq $families[-1] && eof )) {
			foreach my $id( keys( %$seqs ) ){
			    print $tmp $id;
			    print $tmp $seqs->{$id};
			}
			close $tmp;
			$n_proc++; 	    #build the db split number
			my $split_db_path = "${db_path_with_name}_${n_proc}.fa";
			move( $tmp_path, $split_db_path );		    
			gzip_file($split_db_path); # We want DBs to be gzipped.
			unlink($split_db_path); # So we save the gzipped copy, and DELETE the uncompressed copy
			$seqs = {};
			unless( $family eq $families[-1] && eof ){
			    open( TMP, ">${db_path_with_name}.tmp" ) || die "Can't open ${db_path_with_name}.tmp for write: $!\n";
			    $tmp = *TMP;	    
			}
		    }
		} else {
		    #we want a single, large db
		    if( $family eq $families[-1] && eof ) {
			foreach my $id( keys( %$seqs ) ){
			    print $tmp $id;
			    print $tmp $seqs->{$id};
			}
			close $tmp;
			$n_proc++; 	    #build the db split number
			my $split_db_path = "${db_path_with_name}_${n_proc}.fa";
			move( $tmp_path, $split_db_path );		    
			gzip_file($split_db_path); # We want DBs to be gzipped.
			unlink($split_db_path); # So we save the gzipped copy, and DELETE the uncompressed copy
			$seqs = {};
		    }
		}
	    }
	    close FILE;
	    if( $nr_db ){
		#we don't want to keep the copy of the tmp nr file that we created, which was pushed into $family_db_file above
		$self->Shotmap::Notify::print_verbose("removing file $family_db_file\n");
		unlink( $family_db_file );
	    }
	    #calculate the family's length
	    if( $fam_nseqs == 0 ){
		die "Couldn't find any sequences for $family\n";
	    }
	    $family_length = ( $length - $fam_init_len ) / $fam_nseqs; #average length of total sequence found in family
	    if( defined( $family_length ) ){
		print FAMLENS join( "\t", $family, $family_length, $fam_nseqs, "\n" );
	    } else {
		die "Cannot calculate a family length for $family\n";
	    }       	    
	    }
	else { 
	    die "invalid type: <$type>"; 
	}
    }
    close FAMLENS;
    close SEQLENS;
    if( $nr_db ){
	close $redunts;
    }
    #print out the database length
    open( LEN, ">${raw_db_path}/database_length.txt" ) || die "Can't open ${raw_db_path}/database_length.txt for write: $!\n";
    print LEN $length;
    close LEN;    

    print STDERR "Build Search DB: $type DB was successfully built and compressed.\n";
}

sub format_search_db{ #local process only
    my( $self, $db_file, $type ) = @_;
    #my $db_file = $self->Shotmap::Run::get_db_filepath_prefix( $type ) . "_1.fa"; #only ever 1 for local search
    my $compressed = 0; #auto detect if ref-ffdb family files are compressed or not
    unless( -e $db_file ){ #if uncompressed version exists, go with it
	if( -e "${db_file}.gz" ){
	    $compressed = 1;
	}
    }
    if( $compressed ){
	gunzip "${db_file}.gz" => $db_file or die "gunzip failed: $GunzipError\n";
    }
    my $cmd;
    if( $type eq "rapsearch" ){
	my $db_suffix = $self->search_db_name_suffix;
	$cmd = "prerapsearch -d ${db_file} -n ${db_file}.${db_suffix}"; # > /dev/null 2>&1";
    }
    elsif( $type eq "last" ){
	$cmd = "lastdb -p $db_file $db_file";
    }
    elsif( $type eq "blast" ){
	$cmd = "makeblastdb -dbtype prot -in $db_file";
    }
    elsif( $type eq "hmmscan" || $type eq "hmmsearch" ){
	#do nothing
	return;
    }
    else{
	die( "I don't know how to run $type in Shotmap::Run::format_search_db" );
    }
    $self->Shotmap::Notify::print_verbose( $cmd );
    my $results = IPC::System::Simple::capture( $cmd );    
    (0 == $EXITVAL) or die("Error executing $cmd: $results\n");
    if( $compressed ){
	#get rid of the gunzipped copy created above
	unlink( $db_file );
    }
    return $results
}

sub get_db_filepath_prefix{
    my( $self, $type ) = @_;
    #GET DB VARS
    my ( $db_name, $db_dir, $db_filestem );
    if (($type eq "blast") or ($type eq "last") or ($type eq "rapsearch")) {
	$db_name        = $self->search_db_name("blast");
	$db_dir         = $self->search_db_path( "blast" );
	#File::Spec->catdir($self->ffdb(), $BLASTDB_DIR, $db_name);
    }
    if (($type eq "hmmsearch") or ($type eq "hmmscan")) {
	$db_name        = $self->search_db_name("hmm");
	$db_dir         = $self->search_db_path( "hmm" );
	#$db_dir         = File::Spec->catdir($self->ffdb(), $HMMDB_DIR, $db_name);
    }
    $db_filestem = File::Spec->catfile( $db_dir, $db_name ); #only ever 1 for local search
    return $db_filestem;
}

sub _get_family_length{
    my ( $family_db_file, $type ) = @_;
    my $family_length;
    if( $type eq "hmm" ){
	open( FILE, "zcat --force $family_db_file |") || die "Unable to open the file \"$family_db_file\" for reading: $! --"; # zcat --force can TRANSPARENTLY read both .gz and non-gzipped files!
	while(<FILE>){
	    chomp $_;
	    if( $_ =~ m/LENG\s+(\d+)/){
		$family_length = $1;
		last;
	    }
	}
    } elsif( $type eq "blast" ){
	#we calculate length in build_search_db since we open files there anyhow
    }
    else{
	die "Passed an unknown type to get_family_length (received ${type})\n";
    }    
    return $family_length;
}

#this recurses through all subdirs under ref-ffdb to look for the seqs and hmms of interest. Be careful with how
#ref-ffdb is structured!
sub build_family_ref_path_hash{ 
    my ( $self, $ref_ffdb, $type ) = @_;
    #open the ref_ffdb and look for family-related files (hmms and seqs)
    my $family_paths = {};
    my $recurse_lvl = 1; #we use these two vars to limit the number of dirs we look into. Otherwise, code can get lost.
    my $recurse_lim = 1; #turned to 1 from 3 to simplify structure - only work with the top level directory 
    $family_paths = $self->Shotmap::Run::get_family_path_from_dir( $ref_ffdb, $type, $recurse_lvl, $recurse_lim, $family_paths ); 
    return $family_paths; #a hashref
}

sub get_family_path_from_dir{
    my $self = shift;
    my $dir  = shift;
    my $type = shift;
    my $recurse_lvl  = shift; #how many recursions are we on
    my $recurse_lim  = shift; #how many total recursions do we allow?
    my $family_paths = shift; #hashref
    opendir( DIR, $dir ) || die "Can't opendir on $dir\n";
    my @files = readdir( DIR );
    closedir DIR;
    $self->Shotmap::Notify::print_verbose( "Grabbing family paths from $dir\n" );
    foreach my $file( @files ){ 
	next if ( $file =~ m/^\./ );
	#if directories, recurse:
	my $path = $dir . "/" . $file;
	if( -d $path ){
	    $self->Shotmap::Notify::print_verbose("entering $path\n");
	    my $sub_recurse_lvl = $recurse_lvl + 1; #do this so that each of the sister subdirs get processed fairly
	    if( $sub_recurse_lvl >= $recurse_lim ){
		$self->Shotmap::Notify::print_verbose( "Won't go into $path because recursion limit hit. Recursion number is $sub_recurse_lvl\n" );
		next;
	    }
	    else{
		$family_paths = $self->Shotmap::Run::get_family_path_from_dir( $path, $type, $sub_recurse_lvl, $recurse_lim, $family_paths ); 
	    }
	    next;
	}
        #are the top level dirs what we're looking for?
	if( $type eq "hmm" ){ #find hmms and build the db		
	    next if ($file =~ m/tmp/ ); #don't want to grab any tmp files from old, failed run
	    next unless( !-d $file );
	    my $family = $file; #we'll try to parse, but default to file name
	    if( $file =~ m/(.*)\.hmm$/    || 
		$file =~ m/(.*)\.hmm\.gz$/ ){
		$family = $1;
	    }
	    my $hmm_path = "${dir}/$file";
	    $family_paths->{$type}->{$family} = $hmm_path;
	}
	if( $type eq "blast" ){ #find the seqs and build the db
	    next if ($file =~ m/tmp/ ); #don't want to grab any tmp files from old, failed run
	    next unless( !-d $file );
	    my $family = $file; #we'll try to parse, but default to file name
	    if( $file =~ m/(.*)\.fa/  || 
		$file =~ m/(.*)\.faa/ || 
		$file =~ m/(.*)\.pep/ ||
		$file =~ m/(.*)\.aa/  ||
		$file =~ m/(.*)\.fasta/ ){
		$family = $1;
	    }
	    my $seq_path = "${dir}/${file}";
	    $family_paths->{$type}->{$family} = $seq_path;	    
	}
    }
    my $count = scalar( keys ( %{ $family_paths->{$type} } ) );   
    if( $count == 0 ){
	die( "I couldn't identify any properly formatted reference family data files in $dir!" );
    } else {
	print( "Identified $count reference family data files\n" );
    }
    return $family_paths;
}

sub cat_db_split{
    my ($self, $db_path, $n_proc, $ffdb, $suffix, $ra_families_array_ptr, $type, $nr_db) = @_;
    my @families     = @{$ra_families_array_ptr}; # ra_families is a POINTER TO AN ARRAY
    my $split_db_path = "${db_path}_${n_proc}${suffix}";
    my $fh;
    open( $fh, ">> $split_db_path" ) || die "Can't open $split_db_path for write: $!\n";
    foreach my $family( @families ){
	my $compressed = 0; #auto detect if ref-ffdb family files are compressed or not
	if( $family =~ m/\.gz$/ ){
	    $compressed = 1;
	}
	#do we want a nonredundant version of the DB? OBSOLETE. DO THIS VIA build_search_db now
	if( $type eq "blast" && defined($nr_db) && $nr_db ){
	    #make a temp file for the nr 
	    #append famids to seqids within this routine
	    my $tmp = $self->Shotmap::Run::build_nr_seq_db( $family, $suffix, $self->tmp_dir(), $compressed ); #make a tmp file for the nr
	    File::Cat::cat( $tmp, $fh ); 
	    unlink( $tmp ); #delete the tmp file
	}
	#append famids to seqids, don't build NR database
	elsif( $type eq "blast" ){
	    my $tmp = _append_famids_to_seqids( $family, $suffix, $compressed );
	    File::Cat::cat( $tmp, $fh );
	    unlink( $tmp );
	}
	else{
	    if( $compressed ){
		gunzip $family => $fh;
	    }
	    else{
		File::Cat::cat( $family, $fh );
	    }
	}
    }
    close $fh;
    return $split_db_path;
}

sub _append_famids_to_seqids{
    my $family = shift;
    my $suffix = shift;
    my $compressed = shift;
    my $family_tmp = $family . "_tmp";
    my $fh;
    if( $compressed ){
	open( SEQS, "zcat $family|" ) || die "Can't open $family for read: $!\n";
	$fh     = *SEQS;
    } else {
	open( SEQS, "$family" ) || die "Can't open $family for read: $!\n";
	$fh     = *SEQS;
    }
    open( OUT, ">$family_tmp" ) || die "Can't open $family_tmp for write: $!\n";
    my $famid =  _get_famid_from_familydb_path( $family, $suffix, $compressed );
    my $sequence;
    my $header;
    while( <$fh> ){
	chomp $_;
	if( eof ){
	    my ( $id, $desc ) = _parse_seq_id( $header );
	    my $new_header    = ">${id}_${famid} $desc";
	    print OUT "${new_header}\n${sequence}\n";
	}
	if( $_ =~ m/^>/ ){
	    if( defined( $header ) ){
		my ( $id, $desc ) = _parse_seq_id( $header );
		my $new_header    = ">${id}_${famid} $desc";
		print OUT "${new_header}\n${sequence}\n";		
	    }
	    $header = $_;
	    $sequence = ();
	} else {
	    $sequence .= $_;
	}		
    }
    close $fh;
    close OUT;
    return $family_tmp;    
}

sub _parse_seq_id{
    my ( $seq_id ) = @_;
    my $header = ();
    my $desc   = ();
    chomp( $seq_id );
    if( $seq_id =~ m/^>(.*?)\s(.*)$/ ){
	$header = $1;
	$desc   = $2;
    } elsif( $seq_id =~ m/^>(.*?)$/ ){
	$header = $1;
	$desc   = "";
    } else {
	die "Can't parse header data from $seq_id\n";
    }
    return ( $header, $desc );
}

#Note heuristic here: builiding an NR version of each family_db rather than across the complete DB. 
#Assumes identical sequences are in same family, decreases RAM requirement. First copy of seq is retained
#can speed this up by getting out of bioperl if necessary....
sub build_nr_seq_db{
    my $self           = shift;
    my $family         = shift;
    my $suffix         = shift;
    my $tmp_dir        = shift;
    my $compressed     = shift;
    my $dups_list_file = shift;
    
    my( $family_file, $path ) = fileparse( $family );
    my $family_nr             = File::Spec->catfile( $tmp_dir, $family_file . "_nr_tmp" );
    my $fh;
    if( $compressed ){
	open( SEQS, "zcat $family|" ) || die "Can't open $family for read: $!\n";
	$fh     = *SEQS;
    } else {
	open( SEQS, "$family" ) || die "Can't open $family for read: $!\n";
	$fh     = *SEQS;
    }
    open( OUT, ">$family_nr" ) || die "Can't open $family_nr for write: $!\n";
    my $dict    = {};
    my $famid;
    if( $compressed ){
	$famid = _get_famid_from_familydb_path( $family, $suffix . ".gz" );
    } else {
	$famid  = _get_famid_from_familydb_path( $family, $suffix );
    }
    my $sequence;
    my $header;
    while( <$fh> ){
	chomp $_;	
	if( $_ =~ m/^>/ ){
	    if( defined( $header ) ){
		my ( $id, $desc ) = _parse_seq_id( $header );
		my $new_id        = ">${id}_${famid}";
		my $new_header    = ">${id}_${famid} $desc";	    
		if( !defined( $dict->{$sequence} ) ){
		    print OUT "${new_header}\n${sequence}\n";	    
		    $dict->{$sequence} = $id;
		} else { #print out the duplicate sequence pairings
		    if( defined( $dups_list_file ) ){
			my $retained_id = $dict->{$sequence};
			print $dups_list_file join( "\t", $family, $retained_id, $id, "\n" );
		    }
		}
	    }
	    $header = $_;
	    $sequence = ();
	} else {	    $sequence .= $_;
	}		
    }
    #deal with the last line
    if( !defined( $sequence ) ){
	die( "Error parsing sequence from $family before this line: $_\n" );
    }
    my ( $id, $desc ) = _parse_seq_id( $header );
    my $new_id        = ">${id}_${famid}";
    my $new_header    = ">${id}_${famid} $desc";	    
    if( !defined( $dict->{$sequence} ) ){
	print OUT "${new_header}\n${sequence}\n";	    
	$dict->{$sequence} = $id;
    } else { #print out the duplicate sequence pairings
	if( defined( $dups_list_file ) ){
	    my $retained_id = $dict->{$sequence};
	    print $dups_list_file join( "\t", $family, $retained_id, $id, "\n" );
	}
    }
    close $fh;
    close OUT;

    my $gzip_nr = $family_nr . ".gz";
    gzip $family_nr => $gzip_nr || die "gzip failed for $family_nr: $GzipError\n";
    unlink( $family_nr );
    $family_nr = $gzip_nr;
    return $family_nr;
}

#i'm worried that this might break any families that are not formatted ala SFam famids (e.g., Pfam ids)
sub _get_famid_from_familydb_path{
    my $path = shift;
    my $suffix = shift;
    my $compressed;
    if( $compressed ){
	$suffix    = $suffix . ".gz";
    }
    my $famid  = basename( $path, $suffix );
    return $famid;
}

sub _grab_seqs_from_lookup_list{
    my $seq_id_list = shift; #list of sequence ids to retain
    my $seq_file    = shift; #compressed sequence file
    my $out_seqs    = shift; #compressed retained sequences

    my $lookup      = {}; # apparently this is a hash pointer? or list or something? It isn't a "%" variable for some reason.
    print "Selecting reps from $seq_file, using $seq_id_list. Results in $out_seqs\n";
    #build lookup hash
    open( LOOK, $seq_id_list ) || die "Can't open $seq_id_list for read: $!\n";
    while(<LOOK>){
	chomp $_;
	$lookup->{$_}++;
    }
    close LOOK;
    # turned off bioperl because this function is only used in representative selection, which is obsolete
    # and we don't want to require bioperl just for this routine. If we ever turn rep selection on in the future
    # consider a non-bioperl solution.
    my $seqs_in  = ""; #Bio::SeqIO->new( -file => "zcat $seq_file |", -format => 'fasta' );
    my $seqs_out = ""; #Bio::SeqIO->new( -file => ">$out_seqs", -format => 'fasta' );
    while(my $seq = $seqs_in->next_seq()){
	my $id = $seq->display_id();
	if( defined( $lookup->{$id} ) ){
	    $seqs_out->write_seq( $seq );
	}
    }
    gzip_file( $out_seqs );    
    unlink( $out_seqs );
}

#calculates total amount of sequence in a file (looks like actually in a DIRECTORY rather than a file)
sub calculate_blast_db_length{
    my ($self) = @_;

    (defined($self->search_db_name("blast"))) or die "dbname was not already defined! This is a fatal error.";
    (defined($self->ffdb())) or die "ffdb was not already defined! This is a fatal error.";

    my $db_path = File::Spec->catdir($self->ffdb(), $BLASTDB_DIR, $self->search_db_name("blast"));
    opendir( DIR, $db_path ) || die "Can't opendir $db_path for read: $! ";
    my @files = readdir(DIR);
    closedir DIR;
    my $numFilesRead = 0;

    my $PRINT_OUTPUT_EVERY_THIS_MANY_FILES = 25;
    my $lenTotal  = 0;
    foreach my $file (@files) {
	next unless( $file =~ m/\.fa/ ); # ONLY include files ending in .fa
	my $lengthThisFileOnly = get_sequence_length_from_file(File::Spec->catfile($db_path, $file));
	$lenTotal += $lengthThisFileOnly;
	$numFilesRead++;
	if ($numFilesRead == 1 or ($numFilesRead % $PRINT_OUTPUT_EVERY_THIS_MANY_FILES == 0)) {
	    # Print diagnostic data for the FIRST entry, as well as periodically, every so often.
	    $self->Shotmap::Notify::notify("[$numFilesRead/" . scalar(@files) . "]: Got a sequence length of $lengthThisFileOnly from <$file>. Total length: $lenTotal");
	}
    }
    $self->Shotmap::Notify::notify("$numFilesRead files were read. Total sequence length was: $lenTotal");
    return $lenTotal;
}

sub compress_hmmdb{
    my ($file, $force) = @_;
    my @args = ($force) ? ("-f", "$file") : ("$file"); # if we have FORCE on, then add "-f" to the options for hmmpress
    warn "I hope 'hmmpress' is installed on this machine already!";
    my $results  = IPC::System::Simple::capture( "hmmpress " . "@args" );
    (0 == $EXITVAL) or die("Error translating sequences in $file: $results ");
    return $results;
}

#copy a project's ffdb over to the remote server
sub load_project_remote {
    my ($self) = @_;
    my $project_dir_local = $self->project_dir;
    my $remote_dir        = File::Spec->catdir($self->remote_ffdb(), "projects", $self->db_name(),  $self->project_id());
    my $ssh_remote_dir    = $self->remote_connection() . ":" . $remote_dir;
    warn("Pushing $project_dir_local to the remote (" . $self->remote_host() . ") server's ffdb location in <$remote_dir>\n");
    my $remote_cmd = "mkdir -p ${remote_dir}";
    $self->Shotmap::Run::execute_ssh_cmd( $self->remote_connection(), $remote_cmd );
    my $results = $self->Shotmap::Run::transfer_directory($project_dir_local, $ssh_remote_dir);
    return $results;
}

#the qsub -sync y option keeps the connection open. lower chance of a connection failure due to a ping flood, but if connection between
#local and remote tends to drop, this may not be foolproof
sub translate_reads_remote($$$$$) {
    my ($self, $waitTimeInSeconds, $logsdir, $filter_length, $local_copy_of_remote_script) = @_;
    my $method = $self->trans_method;

    #push translation scripts to remote server
    my $connection = $self->remote_connection();
    my $remote_script_dir = $self->remote_scripts_dir();

    my $local_copy_of_remote_handler  = File::Spec->catfile($self->local_scripts_dir(), "remote", "run_metatrans_handler.pl");
    my $metatransPerlRemote = File::Spec->catfile($remote_script_dir, "run_metatrans_handler.pl");
    
    $self->Shotmap::Run::transfer_file_into_directory($local_copy_of_remote_handler, "$connection:$remote_script_dir/"); # transfer the script into the remote directory
    $self->Shotmap::Run::transfer_file_into_directory($local_copy_of_remote_script,  "$connection:$remote_script_dir/"); # transfer the script into the remote directory

    warn "About to translate reads...";

    my $numReadsTranslated = 0;
    foreach my $sample_id( @{$self->get_sample_ids()} ) {
	my $remote_raw_dir    = File::Spec->catdir($self->remote_ffdb(), "projects", $self->db_name, $self->project_id(), $sample_id, "raw");
	my $remote_output_dir = File::Spec->catdir($self->remote_ffdb(), "projects", $self->db_name, $self->project_id(), $sample_id, "orfs");

	$self->Shotmap::Notify::notify("Translating reads on the REMOTE machine, from $remote_raw_dir to $remote_output_dir...");
	#execute the command...
	my $remote_cmd = "perl ${metatransPerlRemote} " . " -i $remote_raw_dir" . " -o $remote_output_dir" . " -w $waitTimeInSeconds" . " -l $logsdir" . " -s $remote_script_dir" . " -f $filter_length -m $method";
	if( $self->verbose ){
	    $remote_cmd .= " -v ";
	}
	my $response   = $self->Shotmap::Run::execute_ssh_cmd( $connection, $remote_cmd );
	$self->Shotmap::Notify::notify("Translation result text, if any was: \"$response\"");

	$self->Shotmap::Notify::notify("Translation complete, Transferring ORFs\n");
	
	my $theOutput = $self->Shotmap::Run::execute_ssh_cmd($connection, "ls -l $remote_output_dir/");
	$self->Shotmap::Notify::notify_verbose("Got the following files that were generated on the remote machine:\n$theOutput");
	(not($theOutput =~ /total 0/i)) or die "Dang! Somehow nothing was translated on the remote machine. " . 
	    "We expected the directory \"$remote_output_dir\" on the machine " . $self->remote_host() . 
	    " to have files in it, but it was totally empty! This means the translation of reads probably failed. " . 
	    "You had better check the logs on the remote machine! There is probably something interesting in the \"" . 
	    File::Spec->catdir($logsdir, "transeq") . "\" directory (on the REMOTE machine!) that will tell you exactly " . 
	    "why this command failed! Check that directory!";

	my $localOrfDir  = File::Spec->catdir($self->get_sample_path($sample_id), "orfs");
	$self->Shotmap::Run::transfer_directory("$connection:$remote_output_dir", $localOrfDir); # This happens in both cases, whether or not the orfs are split!
	$numReadsTranslated++;
    }
    $self->Shotmap::Notify::notify("All reads were translated on the remote server and locally acquired. Total number of translated reads: $numReadsTranslated");
    ($numReadsTranslated > 0) or die "Uh oh, the number of reads translated was ZERO! This probably indicates a serious problem.";
}

sub job_listener($$$$) {
    # Note that this function is a nearly exact copy of "local_job_listener"
    my ($self, $jobsArrayRef, $waitTimeInSeconds, $is_remote) = @_;
    ($waitTimeInSeconds >= 1) or die "Programming error: You can't set waitTimeInSeconds to less than 1 (but it was set to $waitTimeInSeconds)---we don't want to flood the machine with constant system requests.";
    my %statusHash             = ();
    my $startTimeInSeconds = time();
    ($is_remote == 0 or $is_remote == 1) or die "is_remote must be 0 or 1! you passed in <$is_remote>.";
    while (scalar(keys(%statusHash)) != scalar(@{$jobsArrayRef})) { # keep checking until EVERY SINGLE job has a finished status
	#call qstat and grab the output
	my $results = undef;
	if ($is_remote) {
	    $results = $self->Shotmap::Run::execute_ssh_cmd( $self->remote_connection(), "\'qstat\'"); # REMOTE.
	} else { 
	    $results = IPC::System::Simple::capture("ps"); #call ps and grab the output. LOCAL.
	}
	#see if any of the jobs are complete. pass on those we've already finished
	foreach my $jobid( @{ $jobsArrayRef } ){
	    next if( exists( $statusHash{$jobid} ) );
	    if( $results !~ m/$jobid/ ){
		$statusHash{$jobid}++;
	    }
	}
	sleep($waitTimeInSeconds);
    }
    return (time() - $startTimeInSeconds); # return amount of wall-clock time this took
}

sub remote_job_listener{
    my ($self, $jobsArrayRef, $waitTimeInSeconds) = @_;
    return($self->job_listener($jobsArrayRef, $waitTimeInSeconds, 1));
}

sub local_job_listener{
    my ($self, $jobsArrayRef, $waitTimeInSeconds) = @_;
    return($self->Shotmap::Run::job_listener($jobsArrayRef, $waitTimeInSeconds, 0));
}

sub remote_transfer_search_db{
    my ($self, $db_name, $type) = @_;
    my $DATABASE_PARENT_DIR = undef;
    if ($type eq "hmm")   { $DATABASE_PARENT_DIR = $HMMDB_DIR; }
    if ($type eq "blast") { $DATABASE_PARENT_DIR = $BLASTDB_DIR; }
    (defined($DATABASE_PARENT_DIR)) or die "Programming error: the 'type' in remote_transfer_search_db must be either \"hmm\" or \"blast\". Instead, it was: \"$type\". Fix this in the code!\n";
    my $db_dir     = $self->ffdb() . "/${DATABASE_PARENT_DIR}/${db_name}";
    my $remote_dir = $self->remote_connection() . ":" . $self->remote_ffdb() . "/$DATABASE_PARENT_DIR/$db_name";
    return($self->Shotmap::Run::transfer_directory($db_dir, $remote_dir));
}

sub remote_transfer_batch { # transfers HMMbatches, not actually a general purpose "batch transfer"
    my ($self, $hmmdb_name) = @_;
    my $hmmdb_dir   = $self->ffdb() . "/HMMbatches/$hmmdb_name";
    my $remote_dir  = $self->remote_connection() . ":" . $self->remote_ffdb() . "/HMMbatches/$hmmdb_name";
    return($self->Shotmap::Run::transfer_directory($hmmdb_dir, $remote_dir));
}

sub gunzip_file_remote {
    my ($self, $remote_file) = @_;
    my $remote_cmd = "gunzip -f $remote_file";
    return($self->Shotmap::Run::execute_ssh_cmd( $self->remote_connection(), $remote_cmd ));
}

sub gunzip_remote_dbs{
    my( $self, $db_name, $type ) = @_;    
    my $ffdb   = $self->ffdb();
    my $db_dir = undef;
    if ($type eq "hmm")      { $db_dir = "$ffdb/$HMMDB_DIR/$db_name"; }
    elsif ($type eq "blast") { $db_dir = "$ffdb/$BLASTDB_DIR/$db_name"; }
    else                     { die "invalid or unrecognized type."; }

    opendir( DIR, $db_dir ) || die "Can't opendir $db_dir for read: $!";
    my @files = readdir( DIR );
    closedir DIR;
    foreach my $file( @files ){
	next unless( $file =~ m/\.gz/ ); # Skip any files that are NOT .gz files
	my $remote_db_file;
	if( $type eq "hmm" ){   $remote_db_file = $self->remote_ffdb() . "/$HMMDB_DIR/$db_name/$file"; }
	if( $type eq "blast" ){ $remote_db_file = $self->remote_ffdb() . "/$BLASTDB_DIR/$db_name/$file"; }
	$self->Shotmap::Run::gunzip_file_remote($remote_db_file);
    }
}

sub format_remote_blast_dbs{
    my($self, $remote_script_path) = @_;
    my $search_type           = $self->search_type;
    my $remote_database_dir   = File::Spec->catdir($self->remote_ffdb(), $BLASTDB_DIR, $self->search_db_name("blast"));
    my $n_splits              = $self->Shotmap::DB::get_number_db_splits( $search_type ); #do we still need this?
    my $results               = $self->Shotmap::Run::execute_ssh_cmd($self->remote_connection(), "qsub -t 1-${n_splits} -sync y $remote_script_path $remote_database_dir");
}

sub run_search_remote {
    my ($self, $sample_id, $type, $nsplits, $waitTimeInSeconds, $verbose, $forcesearch) = @_;
    my $search_type   = $self->search_type;
    my $search_method = $self->search_method;
    ( $nsplits > 0 ) || die "Didn't get a properly formatted count for the number of search DB splits! I got $nsplits.";
    my $remote_orf_dir             = File::Spec->catdir(  $self->remote_sample_path($sample_id), "orfs");
    my $log_file_prefix            = File::Spec->catfile( $self->remote_project_log_dir(),       "${type}_handler");
    my $remote_results_output_dir  = File::Spec->catdir(  $self->remote_sample_path($sample_id), "search_results", ${type});
    my $db_name                    = $self->search_db_name( $search_type );
    my $remote_db_dir              = $self->remote_search_db; 
    my $remote_script_path         = $self->remote_script_path( $search_method );

    # Transfer the required scripts, such as "run_remote_search_handler.pl", to the remote server. For some reason, these don't get sent over otherwise!
    my @scriptsToTransfer = (File::Spec->catfile($self->local_scripts_dir(), "remote", "run_remote_search_handler.pl")); # just one file for now
    foreach my $transferMe (@scriptsToTransfer) {
	$self->Shotmap::Run::transfer_file_into_directory($transferMe, ($self->remote_connection() . ':' . $self->remote_scripts_dir() . '/')); # transfer the script into the remote directory
    }
    
    # See "run_remote_search" in run_remote_search_handler.pl
    my $remote_cmd  = "perl " . File::Spec->catfile($self->remote_scripts_dir(), "run_remote_search_handler.pl")
	. " --resultdir=$remote_results_output_dir "
	. " --dbdir=$remote_db_dir "
	. " --querydir=$remote_orf_dir "
	. " --dbname=$db_name "
	. " --nsplits=$nsplits "
	. " --scriptpath=${remote_script_path} "
	. " -w $waitTimeInSeconds ";
    if( $forcesearch ){
	$remote_cmd .= " --forcesearch ";
    }
    $remote_cmd .=    "> ${log_file_prefix}.out 2> ${log_file_prefix}.err ";

    my $results     = $self->Shotmap::Run::execute_ssh_cmd($self->remote_connection(), $remote_cmd, $verbose);
    (0 == $EXITVAL) or $self->Shotmap::Notify::warn("Execution of command <$remote_cmd> returned non-zero exit code $EXITVAL. The remote reponse was: $results.");
    return $results;
}

sub run_search{
    my( $self, $sample_id, $type, $waittime, $verbose ) = @_;
    my $nprocs   = $self->nprocs();
    my $n_db_splits = $self->search_db_n_splits( $self->search_type );
    #GET IN/OUT VARS
    my $orfs_dir        = File::Spec->catdir(  $self->get_sample_path($sample_id), "orfs");
    my $log_file_prefix = File::Spec->catfile( $self->project_dir(), "/logs/", "${type}", "${type}_${sample_id}"); #file stem that we add to below
    my $master_out_dir  = File::Spec->catdir(  $self->get_sample_path($sample_id), "search_results", ${type});
    (-d $orfs_dir)       or die "Unexpectedly, the input directory <$orfs_dir> was NOT FOUND! Check to see if this directory really exists.";
    (-d $master_out_dir) or die "Unexpectedly, the output directory <$master_out_dir> was NOT FOUND! Check to see if this directory really exists.";
    my $inbasename  = $self->Shotmap::Run::get_file_basename_from_dir($orfs_dir) . "split_"; 
    if( !defined( $inbasename ) ){
	die( "Couldn't obtain a raw file input basename to input from $orfs_dir!");
    }
    # DECOMPRESS DATABASE FILES IF NEED BE
    my $compressed = 0; #auto detect if ref-ffdb family files are compressed or not
    for( my $j=1; $j<=$n_db_splits; $j++ ){
	# GET DB VARS
	my $suffix = "_${j}.fa";
	if( $self->search_type eq "hmm" ){
	    #$suffix = "_${j}.hmm.gz";
	    $suffix = "_${j}.hmm";
	}
	my $db_file = $self->Shotmap::Run::get_db_filepath_prefix( $type ) . "${suffix}";       
	unless( -e $db_file ){ #if uncompressed version exists, go with it
	    if( -e "${db_file}.gz" ){
		$compressed = 1;
	    }
	}
	if( $compressed ){
	    gunzip "${db_file}.gz" => $db_file or die "gunzip failed: $GunzipError\n";
	}	    	 
    }
    #RUN THE SEARCH
    my $pm = Parallel::ForkManager->new($nprocs);
    $pm->run_on_finish(
	sub{ my ( $parent_id, $exit_code ) = @_;
	     if( $exit_code != 0 ){
		 die "child (parent $parent_id) returned a non-zero exit code! Got $exit_code\n";
	     }
	}
	);
    for( my $i=1; $i<=$nprocs; $i++ ){
        my $pid = $pm->start and next;
        #do some work here                                                                                 
        my $log_file = $log_file_prefix . "_${i}.log";
	my $infile  = File::Spec->catfile( $orfs_dir, $inbasename . $i . ".fa" );
	if( ! -e $infile ){
	    $self->Shotmap::Notify::warn( 
		"I could not find $infile for processing with run_search. This is not "  .
		"necessairly an error (we may have fewer input files that you expect), " .
		"but I recommend verifying"
		);
	    $pm->finish;
	}
	#loop over database splits for each input file
	for( my $j=1; $j<=$n_db_splits; $j++ ){	    
	    # GET DB VARS
	    my $suffix = "_${j}.fa";
	    if( $self->search_type eq "hmm" ){
		#$suffix = "_${j}.hmm.gz";
		$suffix = "_${j}.hmm";
	    }
	    my $db_file = $self->Shotmap::Run::get_db_filepath_prefix( $type ) . "${suffix}";
	    # OUTPUT DIR AND FILES
	    my $outdir  = File::Spec->catdir( $master_out_dir, $inbasename . $i .  ".fa" ); #this is a directory
	    File::Path::make_path($outdir);
	    my $outbasename = "${inbasename}${i}.fa-" . $self->search_db_name($type) . "_${j}.tab"; 
	    my $outfile     = File::Spec->catfile( $outdir, $outbasename );
	    # BUILD THE COMMAND
	    my $cmd;
	    if( $type eq "rapsearch" ){
		my $suffix = $self->search_db_name_suffix;
		my $parse_score = $self->parse_score;
		#$cmd = "rapsearch -b 0 -i $parse_score -q $infile -d ${db_file}.${suffix} -o $outfile > $log_file 2>&1";
		#set -v while we only do best hit. Future class methods will need this off.
		$cmd = "rapsearch -b 0 -v 1 -i $parse_score -q $infile -d ${db_file}.${suffix} -o $outfile > $log_file 2>&1";
	    }
	    elsif( $type eq "rapsearch_accelerated" ){
		my $suffix = $self->search_db_name_suffix;
		my $parse_score = $self->parse_score;
		#$cmd = "rapsearch -b 0 -i $parse_score -a T -q $infile -d ${db_file}.${suffix} -o $outfile > $log_file 2>&1";
		#set -v while we only do best hit. Future class methods will need this off.
		$cmd = "rapsearch -b 0 -v 1 -i $parse_score -a T -q $infile -d ${db_file}.${suffix} -o $outfile > $log_file 2>&1";
	    }       
	    #ADD ADDITIONAL METHODS HERE    
	    elsif( $type eq "blast" ){
		$cmd = "blastp -query $infile -db $db_file -out $outfile -outfmt 6 > $log_file 2>&1";
	    } 
	    elsif( $type eq "last" ){
		my $min_aln_score    = $self->parse_score;
		my $max_multiplicity = 10;
		$cmd = "lastal -e $min_aln_score -f 0 -m $max_multiplicity $db_file $infile -o $outfile > $log_file 2>&1";
	    }
	    elsif( $type eq "hmmsearch" ){
		$cmd = "hmmsearch --noali --domtblout $outfile  $db_file $infile > $log_file 2>&1";
	    }
	    elsif( $type eq "hmmscan" ){
		$cmd = "hmmscan -Z --noali --domtblout $outfile $db_file $infile > $log_file 2>&1";
	    }
	    else {
		die( "I don't know how to process $type in Shotmap::Run::run_search" );
	    }
	    #execute
	    ( defined( $cmd ) ) || die( "Couldn't figure out which command to run. $type was input\n" );
	    $self->Shotmap::Notify::print_verbose( "$cmd\n" );
            #my $results = IPC::System::Simple::capture("$cmd");
            #(0 == $EXITVAL) or die("Error executing this command:\n${cmd}\nGot these results:\n${results}\n");
	    system( $cmd );
	    #compress results
	    if( $type eq "rapsearch" ){
		gzip_file( "${outfile}.m8" );    
		unlink( "$outfile.m8" );
	    } else{
		gzip_file( $outfile );
		unlink( $outfile );
	    }
	}
        $pm->finish; 
    }
    $self->Shotmap::Notify::print( "\tWaiting for local jobs to finish...\n" );
    $pm->wait_all_children;
    $self->Shotmap::Notify::print( "\t...$type finished. Proceeding\n" );
    # COMPRESS DATABASE FILES IF NEED BE
    for( my $j=1; $j<=$n_db_splits; $j++ ){	    
	# GET DB VARS
	my $suffix = "_${j}.fa";
	if( $self->search_type eq "hmm" ){
	    #$suffix = "_${j}.hmm.gz";
	    $suffix = "_${j}.hmm";
	}
	my $db_file = $self->Shotmap::Run::get_db_filepath_prefix( $type ) . "${suffix}";
	if( $compressed ){
	    gzip_file( $db_file );    
	}
    }
    return $self;
}

sub parse_results {
    my ($self, $sample_alt_id, $type, $waitTimeInSeconds, $verbose ) = @_;
    my $nprocs       = $self->nprocs();
    my $proj_dir     = $self->project_dir;
    my $scripts_dir  = $self->local_scripts_dir;
    my $t_score      = $self->parse_score;
    my $t_coverage   = $self->parse_coverage;
    my $t_evalue     = $self->parse_evalue;
    my $trans_meth   = $self->trans_method;
    my $log_file_prefix = File::Spec->catfile( $self->project_dir(), "/logs/", "parse_results", "${type}_${sample_alt_id}"); #file stem that we add to below
    my $script_file     = File::Spec->catfile($self->local_scripts_dir(), "remote", "parse_results.pl"),
    my $orfbasename     = $self->Shotmap::Run::get_file_basename_from_dir(File::Spec->catdir(  $self->get_sample_path($sample_alt_id), "orfs")) . "split_"; 
    my $n_db_splits     = $self->search_db_n_splits( $self->search_type );

    my $pm = Parallel::ForkManager->new($nprocs);
    $pm->run_on_finish(
	sub{ my ( $parent_id, $exit_code ) = @_;
	     if( $exit_code != 0 ){
		 die "child (parent $parent_id) returned a non-zero exit code! Got $exit_code\n";
	     }
	}
	);
    for( my $i=1; $i<=$nprocs; $i++ ){
        my $pid = $pm->start and next;
	for( my $j=1; $j<=$n_db_splits; $j++ ){
	    #do some work here                                                                                 
	    #set some loop specific variables
	    my $log_file = $log_file_prefix . "_${i}.log";	
	    my $resbasename = "${orfbasename}${i}.fa-" . $self->search_db_name($type) . "_${j}.tab";
	    my $infile   = File::Spec->catfile( $self->get_sample_path($sample_alt_id), "search_results", $type, $orfbasename . $i . ".fa", $resbasename );
	    if( $type eq "rapsearch" ){ #rapsearch has extra suffix auto appended to file
		$infile = $infile . ".m8";
	    }
	    if( ! -e $infile && ! -e $infile . ".gz" ){
		$self->Shotmap::Notify::warn( 
		    "I could not find $infile for processing with parse_results. This is not "  .
		    "necessairly an error (we may have fewer input files that you expect), " .
		    "but I recommend verifying"
		    );
		$pm->finish;
	    }
	    my $incompressed = $infile . ".gz";
	    my $query_orfs_file  = File::Spec->catfile( $self->get_sample_path($sample_alt_id), "orfs", $orfbasename . $i . ".fa" );
	    my $cmd  = "perl $script_file "
		. "--results-tab $incompressed "
		. "--orfs-file $query_orfs_file "
		. "--sample-alt-id $sample_alt_id "
		. "--algo $type "
		. "--parse-type best_hit "
		. "--trans-method $trans_meth "
		;	
	    if( defined( $t_score ) ){
		$cmd .= " --score $t_score ";
	    } else {
		$cmd .= " --score NULL ";
	    }
	    if( defined( $t_evalue ) ){
		$cmd .= " --evalue $t_evalue ";
	    } else { 
		$cmd .= " --evalue NULL ";
	    }
	    if( defined( $t_coverage ) ){
		$cmd .= " --coverage $t_coverage ";
	    } else {
		$cmd .= " --coverage NULL ";
	    }
	    #if( $type eq "rapsearch" ){	
	    $cmd .= " &> $log_file"; 
	    $self->Shotmap::Notify::print_verbose( "$cmd\n" );
	    #}
	    
	    #execute
	    #system( $cmd );
	    my $results = IPC::System::Simple::capture("$cmd");
	    (0 == $EXITVAL) or die("Error executing this command:\n${cmd}\nGot these results:\n${results}\n");
	    if( ! -e $infile . ".mysqld" ){
		die( "parse_results.pl failed to produce an output file! This could mean that there are not hits that pass the parsing thresholds ".
		     "or it could indicate an error."
		    );
	    }
	    gzip_file( $infile . ".mysqld" );
	    unlink( $infile . ".mysqld" );
	}
        $pm->finish; 
    }
    $self->Shotmap::Notify::print( "\tWaiting for local jobs to finish..." );
    $pm->wait_all_children;
    $self->Shotmap::Notify::print( "\t...search results are parsed. Proceeding." );
    return $self;
}

#this is a routine we point to when we are taking an old remote run and reparsing locally
sub parse_results_hack {
    my ($self, $sample_id, $type, $waitTimeInSeconds, $verbose ) = @_;
    my $nprocs       = $self->nprocs();
    my $trans_method = $self->trans_method;
    my $proj_dir     = $self->project_dir;
    my $scripts_dir  = $self->local_scripts_dir;
    my $t_score      = $self->parse_score;
    my $t_coverage   = $self->parse_coverage;
    my $t_evalue     = $self->parse_evalue;
    File::Path::make_path( $self->project_dir() . "/logs/parse_results/" );
    my $log_file_prefix = File::Spec->catfile( $self->project_dir(), "/logs/", "parse_results", "${type}_${sample_id}"); #file stem that we add to below
    my $script_file     = File::Spec->catfile($self->local_scripts_dir(), "remote", "parse_results.pl"),
    my $orfbasename     = $self->Shotmap::Run::get_file_basename_from_dir(File::Spec->catdir(  $self->get_sample_path($sample_id), "search_results", "rapsearch")) . "split_"; 
    
    my $nsplits_to_proc = 200;
    my $nloops = ceil ( $nsplits_to_proc / $self->nprocs );
    my $count  = 0;
    
    while( $count < $nloops ){
	$count++;
	
	my $pm = Parallel::ForkManager->new($nprocs);

	for( my $j=1; $j<=$nprocs; $j++ ){
	    my $i   = $j + ( ($count - 1 ) * $nprocs );
	    my $pid = $pm->start and next;
	    #do some work here                                                                                                                                                                                                                   
	    #set some loop specific variables
	    my $indir   = File::Spec->catdir( $self->get_sample_path($sample_id), "search_results", $type, $orfbasename . $i . ".fa");
	    my $log_file = $log_file_prefix . "_${i}.log";     
	    my $res_stem = "${orfbasename}${i}.fa-" . $self->search_db_name($type); #it's always 1 for a local search since we only split metagenome
	    #presumes results are compressed
	    my $resbasename = $res_stem . "_base.tab.m8.gz";
	    $self->Shotmap::Notify::print_verbose( "cat ${indir}/${res_stem}_[0-9]*[!d].gz > ${indir}/${resbasename}\n" ); #[!d].gz because we don't want old mysqld files!
	    system( "cat ${indir}/${res_stem}_[0-9]*[!d].gz > ${indir}/${resbasename}" );
	    
	    my $infile   = File::Spec->catfile( $indir, $resbasename );
	    #parse_results.pl needs to append the .gz extension for proper opening of file:
	    $infile =~ s/\.gz//;
	    #if( $type eq "rapsearch" ){ #rapsearch has extra suffix auto appended to file       	
		#$infile = $infile . ".m8";
	    #}
	    my $query_orfs_file  = File::Spec->catfile( $self->get_sample_path($sample_id), "orfs", $orfbasename . $i . ".fa" );
	    my $cmd  = "perl $script_file "
		. "--results-tab=$infile "
		. "--orfs-file=$query_orfs_file "
		. "--sample-id=$sample_id "
		. "--algo=$type "
		. "--trans-method=$trans_method "
		. "--parse-type=best_hit "
		. "--no_coverage "
		. "--target-skip-string=rep "
		;	
	    if( defined( $t_score ) ){
		$cmd .= " --score=$t_score ";
	    } else {
		$cmd .= " --score=NULL ";
	    }
	    if( defined( $t_evalue ) ){
		$cmd .= " --evalue=$t_evalue ";
	    } else { 
		$cmd .= " --evalue=NULL ";
	    }
	    if( defined( $t_coverage ) ){
		$cmd .= " --coverage=$t_coverage ";
	    } else {
		$cmd .= " --coverage=NULL ";
	    }
	    if( $type eq "rapsearch" ){	
		$cmd .= " &> $log_file"; 
		$self->Shotmap::Notify::print_verbose( "$cmd\n" );
	    }
	    #execute
	    system( $cmd );
	    gzip_file( $infile . ".mysqld" );
	    #we don't want to store the catted results or the uncompressed mysqld file
	    unlink( $infile . ".gz" );
	    unlink( $infile . ".mysqld" );

	    #so that the downstream tools work, we need to rename this to be the _1 file instead of _base
	    my $outfile = $infile . ".mysqld.gz";
	    my $newout  = $outfile;
	    $newout  =~ s/\_base\./\_1\./;
	    move $outfile, $newout;

	    $pm->finish; 
	}
	$self->Shotmap::Notify::print( "\tWaiting for local jobs to finish..." );
	$pm->wait_all_children;
    }
    $self->Shotmap::Notify::print( "\t...search results are parsed. Proceeding." );
    return $self;
}


sub parse_results_remote {
    my ($self, $sample_id, $nsplits, $waitTimeInSeconds, $verbose, $forceparse) = @_;
    ( $nsplits > 0 ) || die "Didn't get a properly formatted count for the number of search DB splits! I got $nsplits.";
    my $search_method = $self->search_method;
    my $search_type   = $self->search_type;
    my $trans_method  = $self->trans_method;
    my $proj_dir      = $self->remote_project_path;
    my $scripts_dir   = $self->remote_scripts_dir;
    my $t_score       = $self->parse_score;
    my $t_coverage    = $self->parse_coverage;
    my $t_evalue      = $self->parse_evalue;
    my $remote_orf_dir             = File::Spec->catdir($self->remote_sample_path($sample_id), "orfs");
    my $log_file_prefix            = File::Spec->catfile($self->remote_project_log_dir(), "run_remote_parse_results_handler");
    my $remote_results_output_dir  = File::Spec->catdir($self->remote_sample_path($sample_id), "search_results", ${search_method});
    my ($remote_script_path, $db_name, $remote_db_dir);
    $remote_script_path        = $self->remote_script_path( "parse_results" );
    if ( $search_type eq "blast" ){
	$db_name               = $self->search_db_name( $search_type );
	$remote_db_dir         = File::Spec->catdir($self->remote_ffdb(), $BLASTDB_DIR, $db_name);
    }
    if ( $search_type eq "hmm" ){
	$db_name               = $self->search_db_name( $search_type );
	$remote_db_dir         = File::Spec->catdir($self->remote_ffdb(), $HMMDB_DIR, $db_name);
    }

    # Transfer the required scripts, such as "run_remote_search_handler.pl", to the remote server. For some reason, these don't get sent over otherwise!
    my @scriptsToTransfer = (File::Spec->catfile($self->local_scripts_dir(), "remote", "run_remote_parse_results_handler.pl"),
			     File::Spec->catfile($self->local_scripts_dir(), "remote", "parse_results.pl"),
	); 
    foreach my $transferMe (@scriptsToTransfer) {
	$self->Shotmap::Run::transfer_file_into_directory($transferMe, ($self->remote_connection() . ':' . $self->remote_scripts_dir() . '/')); # transfer the script into the remote directory
    }
    
    # See "run_remote_search" in run_remote_search_handler.pl
    my $remote_cmd  = "perl " . File::Spec->catfile($self->remote_scripts_dir(), "run_remote_parse_results_handler.pl")
	. " --resultdir=$remote_results_output_dir "
	. " --querydir=$remote_orf_dir "
	. " --dbname=$db_name "
	. " --nsplits=$nsplits "
	. " --scriptpath=${remote_script_path} "
	. " -w $waitTimeInSeconds "
	. " --sample-alt-id=$sample_id "
#	. " --class-id=$classification_id "
	. " --algo=$search_method "
	. " --transmeth=$trans_method "
	. " --proj-dir=$proj_dir "
	. " --script-dir=$scripts_dir";        
    if( defined( $t_score ) ){
	$remote_cmd .= " --score=$t_score ";
    }
    if( defined( $t_evalue ) ){
	$remote_cmd .= " --evalue=$t_evalue ";
    }
    if( defined( $t_coverage ) ){
	$remote_cmd .= " --coverage=$t_coverage ";
    }
    if( $forceparse ){
	$remote_cmd .= " --forceparse ";
    }
    $remote_cmd .=    "> ${log_file_prefix}.out 2> ${log_file_prefix}.err ";

    my $results     = $self->Shotmap::Run::execute_ssh_cmd($self->remote_connection(), $remote_cmd, $verbose);
    (0 == $EXITVAL) or warn("Execution of command <$remote_cmd> returned non-zero exit code $EXITVAL. The remote reponse was: $results.");
    return $results;
}

sub get_remote_search_results {
    my($self, $sample_id, $type) = @_;
    ($type eq "blast" or $type eq "last" or $type eq "rapsearch" or $type eq "hmmsearch" or $type eq "hmmscan") or 
	die "Invalid type passed into get_remote_search_results! The invalid type was: \"$type\".";
    # Note that every sequence split has its *own* output dir, in order to cut back on the number of files per directory.
    my $in_orf_dir = File::Spec->catdir($self->get_sample_path($sample_id), "orfs"); # <-- Always the same input directory (orfs) no matter what the $type is.
    foreach my $in_orfs(@{$self->Shotmap::DB::get_split_sequence_paths($in_orf_dir, 0)}) { # get_split_sequence_paths is a like a custom version of "glob(...)". It may be eventually replaced by "glob."
	warn "Handling <$in_orfs>...";
#	my $remote_results_output_dir = File::Spec->catdir($self->get_remote_sample_path($sample_id), "search_results", $type);
#	my $remoteFile = $self->remote_connection() . ':' . "$remote_results_output_dir/$in_orfs/";
	my $remote_results_output_dir = $self->remote_connection() . ':' . File::Spec->catdir($self->remote_sample_path($sample_id), "search_results", $type, $in_orfs);
	my $local_search_res_dir  = File::Spec->catdir($self->get_sample_path($sample_id), "search_results", $type, $in_orfs);
#	Shotmap::Run::transfer_file_into_directory($remoteFile, "$local_search_res_dir/");
	if( $self->small_transfer ){ #only grab mysqld files
	    $self->Shotmap::Notify::print( "You have --small-transfer set, so I'm only grabbing the .mysqld files from the remote server.\n" );
	    File::Path::make_path( $local_search_res_dir );
	    $self->Shotmap::Run::transfer_file_into_directory("$remote_results_output_dir/*.mysqld*", "$local_search_res_dir/");	    
	} else { #grab everything
	    $self->Shotmap::Run::transfer_directory("$remote_results_output_dir", "$local_search_res_dir");
	}
    }
}

sub classify_reads{
    my( $self, $sample_id, $class_id, $dbh ) = @_;
    #mysql based classification - works well for nonlarge data, but very slow at hiseq depths. Off by default
    $self->Shotmap::DB::classify_orfs_by_sample( $sample_id, $class_id, $dbh, $self->postrarefy_samples() );
    #now get the classified results for this sample, store in results hash
    my $members_rs = $self->Shotmap::DB::get_classified_orfs_by_sample( $sample_id, $class_id, $dbh, $self->postrarefy_samples() );
    #did mysql return any results for this query?
    my $nrows = 0;
    $nrows    = $members_rs->rows();
    $self->Shotmap::print_verbose( "MySQL return $nrows rows for the above query.\n" );
    if( $nrows == 0 ){
    	warn "Since we returned no rows for this classification query, you might want to check the stringency of your classification parameters.\n";
    	next;
    }
    return $members_rs;

}

sub classify_reads_flatfile{
    my( $self, $sample_id, $class_id, $algo ) = @_;
    $self->Shotmap::Notify::notify( "Classifying reads from flatfile for sample ID ${sample_id}\n" );
    my $search_results = File::Spec->catfile($self->get_sample_path($sample_id), "search_results", $algo);
    #my $output_file    = $search_results . "/classmap_cid_" . $class_id . ".tab";
    my $outdir         = File::Spec->catdir($self->project_dir, "/output/Classification_Maps/" );
    if( $self->use_db || $self->iterate_output ){
	$outdir = File::Spec->catdir( $outdir, "class_id_${class_id}" );
    }
    make_path( $outdir );
    my $output_file    = $outdir . "/ClassificationMap_Sample_${sample_id}.tab";
    my $top_type    = $self->top_hit_type; #best_hit or best_in_fam
    my $class_level = $self->class_level;  #read or orf
    #if remote, use splitcat files in search_results/algo dir
    if( $self->remote ){
	#$self->Shotmap::Run::classify_mysqld_results_from_dir( $search_results, $output_file, ".mysqld", $top_type );
	#consider playing with this if we want no splitcat files....
	$self->Shotmap::Run::classify_mysqld_results_from_dir( $search_results, $output_file, ".mysqld", $top_type, "recurse" );
    } else {
	#if local, use the raw mysqld file in each search_results/algo/orf_split/ dir
	$self->Shotmap::Run::classify_mysqld_results_from_dir( $search_results, $output_file, ".mysqld", $top_type, "recurse" );
    }
    #only if the user wants a full database
    unless( $self->is_slim || ! $self->use_db ){ 
        #have yet to write this function...
	$self->Shotmap::DB::load_classifications_from_file( $output_file );
    }
    $self->Shotmap::Notify::print( "\t...classification complete. Classification map located here: ${output_file}" );
    return $output_file;
}

sub build_classification_maps_by_sample{
    my ($self, $sample_id, $class_id, $members_rs ) = @_; 
    #create the outfile
    #my $map    = {}; #maps project_id -> sample_id -> read_id -> orf_id -> famid NO LONGER NEEDED SINCE WE USE R TO PARSE MAP
    my $output = $self->project_dir . "/output/ClassificationMap_Sample_${sample_id}_ClassID_${class_id}";
    if( defined( $self->postrarefy_samples ) ){
	#my @samples   = keys( %$post_rare_reads );
	#my $rare_size = keys( %{ $post_rare_reads->{ $samples[0] } } );
	my $rare_size = $self->postrarefy_samples;
	$output .= "_Rare_${rare_size}";
    }
    $output .= ".tab";
    $self->Shotmap::Notify::notify( "Building a classification map for sample ID ${sample_id}" ); 
    open( OUT, ">$output" ) || die "Can't open $output for write in build_classification_map: $!";    
    print OUT join("\t", "PROJECT_ID", "SAMPLE_ID", "READ_ID", "ORF_ID", "TARGET_ID", "FAMID", "ALN_LENGTH", "READ_COUNT", "\n" );
    #how many reads should we count for relative abundance analysis?
    my $read_count;
    if(!defined( $self->postrarefy_samples() ) ){
	$self->Shotmap::Notify::print_verbose( "Calculating classification results using all reads loaded into the database\n" );
#	$read_count = @{ $self->Shotmap::DB::get_read_ids_from_ffdb( $sample_id ) }; #need this for relative abundance calculations
	$read_count = $self->Shotmap::DB::get_reads_by_sample_id( $sample_id )->count();
    } else{
	$read_count = $self->postrarefy_samples();
    }
    my $max_rows  = 10000;
    my $must_pass = 0; #how many reads get dropped from SQL result set because not sampled in rarefaction stage. Should not be used any longer.
    while( my $rows = $members_rs->fetchall_arrayref( {}, $max_rows ) ){
	foreach my $row( @$rows ){
	    my $orf_alt_id = $ row->{"orf_alt_id"};		
	    my $famid       = $row->{"famid"};
	    my $read_alt_id = $row->{"read_alt_id"};
	    my $target_id   = $row->{"target_id"};
	    my $aln_length  = $row->{"aln_length"};
	    print OUT join("\t", $self->project_id(), $sample_id, $read_alt_id, $orf_alt_id, $target_id, $famid, $aln_length, $read_count, "\n" );
	}
    }
    $self->Shotmap::Notify::print("\tResults are here: ${output}\n" );
    close OUT;
}

#also builds classification map, have to do both in one function b/c of mysql loop
sub calculate_abundances{ 
    my ( $self, $sample_id, $class_id, $abund_type, $norm_type, $members_rs, $dbh ) = @_;
    my $abundance_parameter_id = $self->Shotmap::DB::get_abundance_parameter_id( $abund_type, $norm_type )->abundance_parameter_id();
    #some bookkeeping for our classification map
    my $output = $self->project_dir . "/output/ClassificationMap_Sample_${sample_id}_ClassID_${class_id}";
    if( defined( $self->postrarefy_samples ) ){
	#my @samples   = keys( %$post_rare_reads );
	#my $rare_size = keys( %{ $post_rare_reads->{ $samples[0] } } );
	my $rare_size = $self->postrarefy_samples;
	$output .= "_Rare_${rare_size}";
    }
    $output .= ".tab";
    $self->Shotmap::Notify::print( "\t...Calculating abundances");
    open( OUT, ">$output" ) || die "Can't open $output for write in build_classification_map: $!";    
    print OUT join("\t", "PROJECT_ID", "SAMPLE_ID", "READ_ID", "ORF_ID", "TARGET_ID", "FAMID", "ALN_LENGTH", "READ_COUNT", "\n" );
    #how many reads should we count for relative abundance analysis?
    my $read_count;
    if(!defined( $self->postrarefy_samples() ) ){
	$self->Shotmap::Notify::print_verbose( "Calculating classification results using all reads loaded into the database\n" );
#	$read_count = @{ $self->Shotmap::DB::get_read_ids_from_ffdb( $sample_id ) }; #need this for relative abundance calculations
	$read_count = $self->Shotmap::DB::get_reads_by_sample_id( $sample_id )->count();
    } else{
	$read_count = $self->postrarefy_samples();
    }
    #did mysql return any results for this query?
    my $nrows = 0;
    $nrows    = $members_rs->rows();
    $self->Shotmap::Notify::print_verbose( "MySQL return $nrows rows for the above query.\n" );
    if( $nrows == 0 ){
	warn "Since we returned no rows for this classification query, you might want to check the stringency of your classification parameters.\n";
	next;
    }
    my $max_rows   = 10000;
    my $must_pass  = 0; #how many reads get dropped from SQL result set because not sampled in rarefaction stage. Should not be used any longer.
    my $abundances = {}; #maps families to abundances
    #question: can perl handle the math below? Perhaps we should do this in SQL instead?
    #could call R from Perl if necessary...
    #alternatively, we could touch the database with updates as we progress, keeping only the totals in memory
    while( my $rows = $members_rs->fetchall_arrayref( {}, $max_rows ) ){
	foreach my $row( @$rows ){
	    my $orf_alt_id = $row->{"orf_alt_id"};		
	    my $famid       = $row->{"famid"};
	    my $read_alt_id = $row->{"read_alt_id"};
	    my $target_id   = $row->{"target_id"};
	    my $aln_length  = $row->{"aln_length"};
	    print OUT join("\t", $self->project_id(), $sample_id, $read_alt_id, $orf_alt_id, $target_id, $famid, $aln_length, $read_count, "\n" );
	    my ( $target_length, $family_length );
	    if( $norm_type eq 'target_length' ){
		$target_length = $self->Shotmap::DB::get_target_length( $target_id );
	    } elsif( $norm_type eq 'family_length' ){
		$family_length = $self->Shotmap::DB::get_family_length( $famid );
	    }
	    if( $abund_type eq 'binary' ){
		my $raw;
		if( $norm_type eq 'none' ){
		    $raw = 1;
		} elsif( $norm_type eq 'target_length' ){
		    $raw = 1 / $target_length;
		} elsif( $norm_type eq 'family_length' ){
		    $raw = 1 / $family_length;
		} else{
		    die( "You selected a normalization type that I am not familiar with (<${norm_type}>). Must be either 'none', 'target_length', or 'family_length'\n" );
		}			    
		$abundances->{$famid}->{"raw"} += $raw;
		$abundances->{"total"}++; #we want RPKM like abundances here, so we don't carry the length of the gene/family in the total 		

	    } elsif( $abund_type eq 'coverage' ){ #number of bases in read that match the family
		my $coverage;
		#have to accumulate coverage totals for normalization as we loop
		if( $norm_type eq "none" ){
		    $coverage = $aln_length;
		} elsif( $norm_type eq "target_length" ){
		    $coverage = $aln_length / $target_length;
		} elsif( $norm_type eq "family_length" ){
		    $coverage = $aln_length / $family_length;
		} else{
		    die( "You selected a normalization type that I am not familiar with (<${norm_type}>). Must be either 'none', 'target_length', or 'family_length'\n" );
		}
		$abundances->{$famid} += $coverage;
		$abundances->{"total"} += $coverage;
	    } else{
		die( "You are trying to calculate a type of abundance that I'm not aware of. Received <${abund_type}>. Exiting\n" );		
	    }	   
	}
    }
    #now that all of the classified reads are processed, calculate relative abundances
    $self->Shotmap::Notify::print( "...classification map results: $output" );
    #now that all of the classified reads are processed, calculate relative abundances
    $self->Shotmap::Notify::notify( "Calculating abundance for sample ID $sample_id" );
    $self->Shotmap::Notify::print_verbose( "Inserting Abundance Data\n" );
    my $total = $abundances->{"total"};
    foreach my $famid( keys( %{ $abundances } ) ){
	next if( $famid eq "total" );
	my $raw = $abundances->{$famid};
	my $ra  = $raw / $total;
	#now, insert the data into mysql.
	$self->Shotmap::DB::insert_abundance( $sample_id, $famid, $raw, $ra, $abundance_parameter_id, $class_id );
    }
    $self->Shotmap::Notify::print( "\t...abundance calculation complete. Proceeding." );
    return $self;
}

sub calculate_abundances_flatfile{
    my ( $self, $sample_id, $class_id, $abundance_parameter_id, $class_map, $length_hash ) = @_;
    my $norm_type  = $self->normalization_type;
    my $abund_type = $self->abundance_type; 
    #do rarefaction here
    my $rare_type = $self->rarefaction_type();
    my $rare_ids = (); #hashref
    my $abundances = (); #maps families to abundances
    my $statistics = ();
    my $seed_string; #if rarefing
    #now that all of the classified reads are processed, calculate relative abundances
    $self->Shotmap::Notify::notify( "Calculating abundance for sample ID $sample_id" );
    if( defined( $self->postrarefy_samples ) ){
	$self->Shotmap::Notify::print( "\tRarefying sample..." );
	#randomly grab sequence identifiers and build $rare_ids->{$seq_id}
	( $rare_ids, $seed_string ) = $self->Shotmap::Run::get_post_rarefied_reads_flatfile( $sample_id, $rare_type );	
	if( !defined( $rare_ids ) ){
	    die "Something went wrong during rarefaction; got a null rare_ids hash";
	}
	my $outdir     = File::Spec->catdir( 
	    $self->project_dir, "output" );
#"cid_${class_id}_aid_${abundance_parameter_id}"
	if( $self->use_db || $self->iterate_output ){
	    $outdir = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abundance_parameter_id}" );
	}
	$outdir = File::Spec->catdir( $outdir, "Rarefied_sequences" );
	if( ! -d $outdir ){
	    File::Path::make_path($outdir);
	}
	my $rare_out   = $outdir . "/Rarefied_Sequences_Sample_${sample_id}.txt";
	open( RARE, ">$rare_out" ) || die "Can't open $rare_out for write: $!\n";
	foreach my $id ( keys( %$rare_ids ) ){
	    print RARE "$id\n";
	}
	close RARE;
	$self->Shotmap::Notify::print( "\t...rarefaction complete! Selected sequence ids can be found here: $rare_out" );
    }
    my $read_count;
    if(!defined( $self->postrarefy_samples() ) ){
	$self->Shotmap::Notify::print( "\tCalculating abundances without rarefaction" );
	#$read_count = $self->Shotmap::DB::get_reads_by_sample_id( $sample_id )->count(); 
        #flat file alternative here: 
	if( $self->class_level eq "read" ){
	    if( defined( $self->prerarefy_samples() ) ){
		$read_count = $self->prerarefy_samples();
	    } else {
		#$read_count = $self->Shotmap::Run::count_objects_in_files( $self->get_sample_path($sample_id) . "/raw/", "read" );
		$read_count = $self->Shotmap::Run::count_objects_in_files( $self->raw_data, "read" );
	    }
	} elsif( $self->class_level eq "orf" ){
	    $read_count = $self->Shotmap::Run::count_objects_in_files( $self->get_sample_path($sample_id) . "/orfs/", "read" );
	}
    } else{
	$read_count = $self->postrarefy_samples();
    }    
    $statistics->{"total_seqs"} = $read_count;
    #we no longer spend the disc to produce rarefaction specific class map. just print read/orf ids    
    if( 0 ){
	my $output = $self->ffdb() . "/projects/" . $self->db_name . "/" . 
	    $self->project_id() . 
	    "/output/ClassificationMap_Sample_${sample_id}_ClassID_${class_id}_AbundanceID_${abundance_parameter_id}.tab";
	if( defined( $self->postrarefy_samples ) ){
	    #my @samples   = keys( %$post_rare_reads );
	    #my $rare_size = keys( %{ $post_rare_reads->{ $samples[0] } } );
	    my $rare_size = $self->postrarefy_samples;
	    $output .= "_Rare_${rare_size}";
	}
	$output .= ".tab";
	open( OUT, ">$output" ) || die "Can't open $output for write: $!";    
	print OUT join("\t", 
		       "PROJECT_ID", "SAMPLE_ID", "READ_ID", 
		       "ORF_ID", "TARGET_ID", "FAMID", 
		       "ALN_LENGTH", "READ_COUNT", 
		       "\n" );
    }
    $self->Shotmap::Notify::print( "\tCalculating abundances..."); 
    $self->Shotmap::Notify::print_verbose( "\t...processing $class_map" );
    open( MAP, $class_map ) || die "Can't open $class_map for read: $!\n";
    my $count = 0;
    #$statistics->{"class_seqs"} = 0;
    #$abundances->{"total"}      = 0;
    while(<MAP>){
	$count++;
	chomp $_;
	my ( $orf_alt_id, $read_alt_id, $sample, 
	     $target_id, $famid, $score, $evalue, 
	     $coverage, $aln_length 
	    ) = split( "\,", $_ );
	if( defined( $self->postrarefy_samples ) ){
	    if( $rare_type =~ "read" ){ #read or class_read
		my $trun_alt_id; #going to get rid of -rl\d+$ for compressed postrare
		if( $read_alt_id =~ m/(.*)\-rl\d+$/ ){
		    $trun_alt_id = $1;
		} else {
		    die "Can't parse read length string for $read_alt_id\n";
		}
		next unless(
		    defined( $rare_ids->{$read_alt_id} ) ||
		    defined( $rare_ids->{$trun_alt_id} ) );
	    }
	    if( $rare_type =~ "orf" ){ #orf or class orf
		next unless defined( $rare_ids->{$orf_alt_id} );
	    }
	}
	$statistics->{"counts"}->{$famid}++;
	$statistics->{"class_seqs"}++;

	#see note above about no longer needing this
	if( 0 ){
	    print OUT join("\t", $self->project_id(), $sample_id, 
			   $read_alt_id, $orf_alt_id, $target_id, 
			   $famid, $aln_length, $read_count, 
			   "\n" );
	}	
	my ( $target_length, $family_length );
	if( $norm_type eq 'target_length' ){
	    $target_length = $length_hash->{$target_id};
	    if( !defined( $target_length ) ){
		die( "Can't calculate the length of hit $target_id" );
	    }
	    if( $abund_type eq 'rpkg' ){
		$target_length = $target_length / 1000;
	    }
	} elsif( $norm_type eq 'family_length' ){
	    $family_length = $length_hash->{$famid};
	    if( $abund_type eq 'rpkg' ){
		$family_length = $family_length / 1000;
	    }
	}
	if( $abund_type eq 'counts' || 
	    $abund_type eq 'rpkg'   ){
	    my $raw;
	    if( $norm_type eq 'none' ){
		$raw = 1;
	    } elsif( $norm_type eq 'target_length' ){
		$raw = 1 / $target_length;
	    } elsif( $norm_type eq 'family_length' ){
		$raw = 1 / $family_length;
	    } else{
		die( "You selected a normalization type that I am not familiar with (<${norm_type}>). " . 
		     "Must be either 'none', 'target_length', or 'family_length'\n" );
	    }			    
	    $abundances->{$famid} += $raw;
	    $abundances->{"total"}++; #we want RPKM like abundances here, so we don't carry the length of the gene/family in the total 			    
	} elsif( $abund_type eq 'coverage' ){ #number of bases in read that match the family
	    my $coverage;
	    #have to accumulate coverage totals for normalization as we loop
	    if( $norm_type eq "none" ){
		$coverage = $aln_length;
	    } elsif( $norm_type eq "target_length" ){
		$coverage = $aln_length / $target_length;
	    } elsif( $norm_type eq "family_length" ){
		$coverage = $aln_length / $family_length;
	    } else{
		die( "You selected a normalization type that I am not familiar with (<${norm_type}>). Must be either 'none', 'target_length', or 'family_length'\n" );
	    }
	    $abundances->{$famid}  += $coverage;
	    $abundances->{"total"} += $coverage;
	} else{
	    die( "You are trying to calculate a type of abundance that I'm not aware of. Reveived <${abund_type}>. Exiting\n" );		
	}	   
	if( ($count%10000 ) == 0 ){
	    $self->Shotmap::Notify::print_verbose( "\t...processed $count rows in classification map...\n" );
	}
    }
    $self->Shotmap::Notify::print( "\t...abundances calculated\n" );
#off for troubleshooting
    if( 0 ){
	if( $self->database() ){   
	    #now, insert the data into mysql.
	    $self->Shotmap::Notify::print( "\tInserting Abundance Data into database....\n" );
	    $self->Shotmap::Run::insert_abundance_hash_into_database( $sample_id, $class_id, $abundance_parameter_id, $abundances, $statistics );
	}
    }

    $self->Shotmap::Notify::print( "\tBuilding an abundance map..." );
    my $abund_map = $self->Shotmap::Run::build_sample_abundance_map_flatfile( $sample_id, $class_id, $abundance_parameter_id, $abundances, $statistics );
    $abundances = ();
    $statistics = ();
    $self->Shotmap::Notify::print( "\t...abundance calculation complete. Abundance map located here: ${abund_map}\n" );
    return $self;
}

sub insert_abundance_hash_into_database{
    my ( $self, $sample_id, $class_id, $abund_param_id, $abundances, $statistics ) = @_;
    my $total = $abundances->{"total"};
    my $tot_reads   = $statistics->{"total_seqs"};
    foreach my $famid( keys( %{ $abundances } ) ){
	next if( $famid eq "total" );
	my $raw = $abundances->{$famid};
	my $ra  = $raw / $total;
	if( $self->ags_method eq "microbecensus" ){
	    my $read_len = $self->sample_ags( $sample_id, "read_length");
	    my $ags      = $self->sample_ags( $sample_id, "ags" );
	    #my $n_reads  = $self->sample_ags( $sample_id, "n_reads_sampled" );
	    my $n_reads  = $tot_reads;
	    my $total_bp = $read_len * $n_reads;
	    #do the correction
	    $raw         = $raw / ( $total_bp / $ags );
	}
	else{
	    #do nothing or add additional methods in future.
	}
	$self->Shotmap::DB::insert_abundance( $sample_id, $famid, $raw, $ra, $abund_param_id, $class_id );
    }
    return $self;
}

sub build_sample_abundance_map_flatfile{
    my( $self, $sample_id, $class_id, $abund_param_id, $abundances, $statistics ) = @_;
    #dump family abundance data for each sample id to flat file
    
    my $outdir     = File::Spec->catdir( 
	$self->project_dir, "output" );
    if( $self->use_db || $self->iterate_output ){
	$outdir = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}" );
    }
    if( $self->filter_hits ){
	$outdir = File::Spec->catdir( $outdir, "Abundances_Filtered" );
    } else {
	$outdir = File::Spec->catdir( $outdir, "Abundances" );
    }
    File::Path::make_path($outdir);
    #get the classification/abundance statistics, store in memory, 
    #will print in print_sample_abundance_statistics
    my $stats_output = $outdir . "/Abundance_Statistics_Sample_{$sample_id}.tab";
    my $total       = $abundances->{"total"};
    my $tot_reads   = $statistics->{"total_seqs"};
    my $class_reads = $statistics->{"class_seqs"};
    print "total is $total, total reads is $tot_reads, and class_reads is $class_reads\n";
    #save some classification statistics for updated metadata output
    $self->sample_stats( $sample_id, "total_abundance", $total );
    $self->sample_stats( $sample_id, "total_reads", $tot_reads );
    $self->sample_stats( $sample_id, "class_reads", $class_reads );
    #test some output
    print $self->sample_stats( $sample_id, "total_abundance" ) . "\n";
    print $self->sample_stats( $sample_id, "total_reads" ) . "\n";
    print $self->sample_stats( $sample_id, "class_reads" ) . "\n";

    #print the abundance data frame
    my $output = $outdir . "/Abundance_Data_Frame_sample_${sample_id}.tab";
    open( ABUND, ">$output"  ) || die "Can't open $output for write: $!\n";
    print ABUND join( "\t", "Sample.Name", "Family.ID", "Counts", 
		      "Abundance", "Relative.Abundance", 
		      #"TOT.ABUND", "CLASS.SEQS", "TOT.SEQS",
		      "\n" );
    if( $self->ags_method eq "microbecensus" ){
	#Parse the ags data here in case of reload 
	my $ags_path   = File::Spec->catdir($self->get_sample_path($sample_id), "ags", $self->ags_method);     
	my $ags_output = File::Spec->catfile( $ags_path, $sample_id . "_ags.mc" );
	$self->Shotmap::Run::parse_microbecensus( $sample_id, $ags_output );
    }
    foreach my $famid( keys( %{ $abundances } ) ){
	next if( $famid eq "total" );
	my $raw = $abundances->{$famid};
	my $ra  = $raw / $total;
	if( $self->ags_method eq "microbecensus" ){
	    my $read_len = $self->sample_ags( $sample_id, "read_length");
	    my $ags      = $self->sample_ags( $sample_id, "ags" );
	    #my $n_reads = $self->sample_ags( $sample_id, "n_reads_sampled" );
	    my $n_reads  = $tot_reads;
	    my $total_bp = $read_len * $n_reads;
	    #do the correction
	    $raw         = $raw / ( $total_bp / $ags );
	} else {
	    #do nothing or add additional methods
	}
	my $count = $statistics->{"counts"}->{$famid};
	print ABUND join( "\t", $sample_id, $famid, $count, $raw, $ra, 
			  #$total, $class_reads, $tot_reads, 
			  "\n" );
    }
    close ABUND;
    return $output;
}

sub print_sample_abundance_statistics{
    my( $self, $class_id, $abund_param_id ) = @_;       
    my $outdir     = File::Spec->catdir( 
	$self->project_dir, "output" );
    if( $self->use_db || $self->iterate_output ){
	$outdir = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}" );
    }
    if( $self->filter_hits ){
	$outdir = File::Spec->catdir( $outdir, "Abundances_Filtered" );
    }
    $outdir = File::Spec->catdir( $outdir, "Abundances" );
    File::Path::make_path($outdir);
    #print the classification/abundance statistics
    my $stats_output = $outdir . "/Abundance_Statistics.tab";
    open( STATS, ">$stats_output" ) || die "Can't open $stats_output for write:\n";
    print STATS join( "\t", "Sample.Name", "Total.Processed.Reads", "Classified.Reads", "Total.Sample.Abundance", "\n" );
    foreach my $sample_id( @{ $self->get_sample_alt_ids() } ){
	my $total_abund = $self->sample_stats( $sample_id, "total_abundance" );
	my $total_reads = $self->sample_stats( $sample_id, "total_reads"     );
	my $class_reads = $self->sample_stats( $sample_id, "class_reads"     );
	print STATS join( "\t", $sample_id, $total_reads, $class_reads, $total_abund, "\n" );
    }
    close STATS;
    return;
}

sub load_sample_abundance_statistics{
    my( $self, $class_id, $abund_param_id ) = @_;       
    my $outdir     = File::Spec->catdir( 
	$self->project_dir, "output" );
    if( $self->use_db || $self->iterate_output ){
	$outdir = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}" );
    }
    $outdir = File::Spec->catdir( $outdir, "Abundances" );
    #print the classification/abundance statistics
    my $stats_output = $outdir . "/Abundance_Statistics.tab";
    open( STATS, "$stats_output" ) || die "Can't open $stats_output for write:\n";
    while(<STATS>){
	chomp $_;
	next if ( $_ =~ m/^Sample\.Name/ || $_ =~ m/^$/ );
	my( $sample_id, $tot_reads, $class_reads, $total ) = split( "\t", $_ );
	$self->sample_stats( $sample_id, "total_abundance", $total   );
	$self->sample_stats( $sample_id, "total_reads", $tot_reads   );
	$self->sample_stats( $sample_id, "class_reads", $class_reads );       
    }
    close STATS;
    return;
}

sub get_post_rarefied_reads_flatfile{
    my ( $self, $sample_id, $rare_type, $check ) = @_;
    if( ! defined( $check ) ){
	$check = 0;
    }
    my $size = $self->postrarefy_samples;
    my $rare_ids = (); #hashref
    my $draws    = (); #hashref
    my $seed_string;
    my $path;
    if( $rare_type eq "read" ){
	$self->Shotmap::Notify::print_verbose( "\t...rarefying reads for sample $sample_id at depth of $size\n" );
	#$path = $self->get_sample_path($sample_id) . "/raw/";
	$path = $self->raw_data();
    } elsif( $rare_type eq "orf" ){
	$self->Shotmap::Notify::print( "\t...rarefying orfs for sample $sample_id at depth of $size\n" );
	$path = $self->get_sample_path($sample_id) . "/orfs/";
    } elsif( $rare_type eq "class_read" ){	
	$self->Shotmap::Notify::print( "\t...rarefying classified reads for sample $sample_id at depth of $size\n" );	
	if( $self->filter_hits() ){
	    my $outdir = File::Spec->catdir( $self->project_dir, "output/" );
	    if( $self->use_db || $self->iterate_output ){
		die( "This doesn't yet work for iterate_output!" );
		#$outdir         = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}");
	    }    
	    $path = $outdir . "/Classification_Maps_Filtered_Mammal/ClassificationMap_Sample_${sample_id}.filtered.mammals.tab";
	} else {
	    $path = $self->search_results($sample_id) . "/classmap_cid_" . $self->classification_id . ".tab";
	}
    } elsif( $rare_type eq "class_orf" ){
	$self->Shotmap::Notify::print( "\t...rarefying classified orfs for sample $sample_id at depth of $size\n" );
	$path = $self->search_results($sample_id) . "/classmap_cid_" . $self->classification_id . ".tab";
    } else {
	die( "You provided a post rarefaction type that I do not understand!\n" );
    }  
    if( !defined( $path) ){
	die "You didn't provide a properly formatted path in get_post_rarefied_reads_flatfile\n";
    }
    #my $max = $self->Shotmap::Run::count_objects_in_files( $path, $rare_type );
    my $max = $self->Shotmap::Run::count_objects_in_files( $path, $rare_type );
    if( $check == 1 ){
	my $bit = 1;
	if( $max < $size ){
	    warn( "There are not enough ${rare_type}s in sample ${sample_id} to rarefy to a depth of ${size} (only found $max). I will have to skip all downstream analyses for this sample.\n" );
	    $bit = 0;
	}
	return $bit;
    }
    ( $draws, $seed_string ) = $self->Shotmap::Run::generate_random_samples( $size, $max, $seed_string );
    $rare_ids = $self->Shotmap::Run::sample_objects_in_files( $path, $rare_type, $draws );
    $draws = (); #cleanup
    return ( $rare_ids, $seed_string )
}

sub generate_random_samples{
    my( $self, $size, $max, $seed_string ) = @_;
    #random sample $size elements from 0..$max
    my @seed = ();
    if( defined( $seed_string ) ){
	@seed = split( "\_", $seed_string );
    } else {
	@seed  = random_get_seed();
	$seed_string = $seed[0] . "_" . $seed[1];
    }
    random_set_seed( @seed ); #may want to optionally take a user defined seed_string at a later date.
    my $draws = ();
    for( 1..$size ){
	my $draw = random_uniform_integer( 1, 1, $max );
	redo if( exists( $draws->{$draw} ) );
	$draws->{$draw}++;
    }    
    return ( $draws, $seed_string );
}

sub count_objects_in_files{
    my( $self, $input, $type ) = @_;
    my $count = 0;
    if( $type eq "read" ||
	$type eq "orf" ){
	if( -d $input ){
	    opendir( DIR, $input ) || die "Can't opendir on $input: $!\n";
	    my @files = sort( readdir( DIR ) ); #sorting is important for consistent drawing
	    closedir( DIR );
	    foreach my $file( @files ){
		next unless( $file =~ m/\.fa/ );
		my $fh;
		if( $file =~ m/\.gz$/ ){
		    open( $fh, "zmore ${input}/${file} |" ) || die "Can't open ${input}/${file} for read in count_objects_in_file: $!\n";
		} else {
		    open( $fh, "${input}/${file}" ) || die "Can't open ${input}/${file} for read in count_objects_in_file: $!\n";
		}
		while(<$fh>){
		    if( $_ =~ m/^>/ ){
			$count++;
		    }
		}
		close( $fh );
	    }	    
	} elsif( -e $input ){ #is just a single input file
	    next unless( $input =~ m/\.fa/ );
	    my $fh;
	    if( $input =~ m/\.gz$/ ){
		open( $fh, "zmore ${input} |" ) || die "Can't open ${input} for read in count_objects_in_file: $!\n";
	    } else {
		open( $fh, "${input}" ) || die "Can't open ${input} for read in count_objects_in_file: $!\n";
	    }
	    while(<$fh>){
		if( $_ =~ m/^>/ ){
		    $count++;
		}
	    }
	    close( $fh );	    
	} else {
	    die "In count_objects_in_file: $input doesn't exist!\n";
	}
    } elsif( $type eq "class_read" || $type eq "class_orf" ){
	if( -e $input ){
	    my $fh;
	    if( $input =~ m/\.gz$/ ){
		open( $fh, "zmore $input|" ) || die "Can't open $input for read: $!\n";
	    } else {
		open( $fh, $input ) || die "Can't open $input for read: $!\n";
	    }
	    my $ids = (); #hashref
	    while( <$fh> ){
		chomp $_;
		my( $orf_alt_id, $read_alt_id, @row ) = split( "\,", $_ );
		if( $type eq "class_read" ){
		    $ids->{$read_alt_id}++;
		} elsif( $type eq "class_orf" ){
		    $ids->{$orf_alt_id}++;
		}		
	    }
	    close $fh;
	    $count = scalar( keys( %$ids ) );
	    $ids = (); #cleanup
	} else {
	    die "In count_objects_in_file: $input doesn't exist!\n";
	}
    } else {
	die "You tried to count_objects_in_files but supplied an incorrect type. You gave me <${type}>.";
    }
    return $count;
}

sub sample_objects_in_files{
    my( $self, $input, $type, $draws ) = @_; #draws is a hashref
    #$draws points to rows in our file (or ordered files) that we should draw from
    my $id_hash = (); #a hashref
    my $count   = 1;
    if( $type eq "read" || $type eq "orf" ){
	if( -d $input ){
	    opendir( DIR, $input ) || die "Can't opendir on $input: $!\n";
	    my @files = sort( readdir( DIR ) ); #sorting is important for consistent drawing
	    closedir( DIR );
	    foreach my $file( @files ){
		open( FILE, "${input}/${file}" ) || die "Can't open ${input}/${file} for read in sample_objects_in_file: $!\n";
		while(<FILE>){
		    if( $_ =~ m/^>/ ){
			if( defined( $draws->{$count} ) ){
			    my $id = _get_header_part_before_whitespace( $_ );
			    $id =~ s/\>//;
			    $id_hash->{$id}++;
			}
			$count++;
		    }
		}
		close( FILE );
	    }
	} elsif( -e $input ){ #is just a single file input
	    my $fh;
	    if( $input =~ m/\.gz$/ ){
		open( $fh, "zmore ${input} |" ) || die "Can't open ${input} for read in count_objects_in_file: $!\n";
	    } else {
		open( $fh, "${input}" ) || die "Can't open ${input} for read in count_objects_in_file: $!\n";
	    }
	    while(<$fh>){
		if( $_ =~ m/^>/ ){
		    if( defined( $draws->{$count} ) ){
			my $id = _get_header_part_before_whitespace( $_ );
			$id =~ s/\>//;
			$id_hash->{$id}++;
		    }
		    $count++;
		}
	    }
	    close( $fh );
	} else {
	    die "In sample_objects_in_file: $input doesn't exist!\n";
	}
    } elsif( $type eq "class_read" || $type eq "class_orf" ){
	if( -e $input ){
	    open( FILE, $input ) || die "Can't open $input for read: $!\n";
	    my $ids = (); #hashref
	    while( <FILE> ){
		chomp $_;
		if( defined( $draws->{$count} ) ){
		    my( $orf_alt_id, $read_alt_id, @row ) = split( "\,", $_ );
		    if( $type eq "class_read" ){
			$id_hash->{$read_alt_id}++;
		    } elsif( $type eq "class_orf" ){
			$id_hash->{$orf_alt_id}++;
		    }		
		}
		$count++;
	    }
	} else {
	    die "In sample_objects_in_file: $input doesn't exist!\n";
	}	
    } else {
	die "You tried to sample_objects_in_files but supplied an incorrect type. You gave me <${type}>.";
    }
    return $id_hash;
}

sub _get_header_part_before_whitespace($) {
    my ($header) = @_;
    if($header =~ m/^(.*?)\s/){
	return($1); # looks like we only want... the part BEFORE the space?
    } else {
	return $header; # unmodified header is just fine, thank you
    }
}


#this is inefficient for large data. Should no longer be used.
sub get_post_rarefied_reads{
    my( $self, $sample_id, $read_number, $is_slim, $post_rare_reads ) = @_;
    if( !defined( $post_rare_reads ) ){
	$post_rare_reads = {}; #hashref that maps sample id to read ids
    }
    #first, get a list of read ids either from the flat file or the database
    my @read_ids = ();
    my @selected_ids = ();
    if( $is_slim ){ #get from the flat file
	@read_ids = @{ $self->Shotmap::DB::get_read_ids_from_ffdb( $sample_id ) };
	#make sure we're not asking for more sampled reads than there are reads in the DB
	if( scalar( @read_ids ) < $read_number ){
	    warn( "You are asking for $read_number sampled reads but I can only find " . scalar(@read_ids) . " for sample ${sample_id}. Exiting\n" );
	    die;
	}
	@selected_ids = @{ _random_sample_from_array( $read_number, \@read_ids ) };
    }
    else{ #get from the database
	my $reads = get_reads_by_sample_id( $sample_id );
	while( my $read = $reads->next ){
	    my $read_id = $read->read_id;
	    push( @read_ids, $read_id );
	}
	#make sure we're not asking for more sampled reads than there are reads in the DB
	if( scalar( @read_ids ) < $read_number ){
	    warn( "You are asking for $read_number sampled reads but I can only find " . scalar(@read_ids) . " for sample ${sample_id}. Exiting\n" );
	    die;
	}       
	@selected_ids = @{ _random_sample_from_array( $read_number, \@read_ids ) };
    }
    foreach my $selected_id( @selected_ids ){
	$post_rare_reads->{$sample_id}->{$selected_id}++; #should never be greater than 1.....
    }
    return $post_rare_reads;
}

sub build_intersample_abundance_map{
    my( $self, $class_id, $abund_param_id ) = @_;
    #dump family abundance data for each sample id to flat file
    my $outdir     = File::Spec->catdir( $self->project_dir, "output" );
    if( $self->use_db || $self->iterate_output ) {
	$outdir = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}" );
    }
    $outdir = File::Spec->catdir( $outdir, "Abundances" );
    File::Path::make_path($outdir);
    my $sample_abund_out  = $outdir . "/Abundance_Map_All_Samples.tab";
    open( ABUND, ">$sample_abund_out"  ) || die "Can't open $sample_abund_out for write: $!\n";
    my $max_rows          = 10000;
    my $dbh               = $self->Shotmap::DB::build_dbh();
    print ABUND join( "\t", "SAMPLE.ID", "FAMILY.ID", "COUNTS", 
		            "ABUNDANCE", "REL.ABUND", "TOT.ABUND", 
		            "CLASS.SEQS", "TOT.SEQS",
		      "\n" );

    foreach my $sample_id( @{ $self->get_sample_ids() } ){
	my $abunds_rs   = $self->Shotmap::DB::get_sample_abundances_for_all_classed_fams( $dbh, $sample_id, $class_id, $abund_param_id );
	while( my $rows = $abunds_rs->fetchall_arrayref( {}, $max_rows ) ){
	    foreach my $row( @$rows ){ 
		my $famid              = $row->{"famid"};
		my $abundance          = $row->{"abundance"};
		my $relative_abundance = $row->{"relative_abundance"};
		if( !defined( $abundance) ){
		    $abundance = 0;
		    $relative_abundance = 0;
		}
		print ABUND join( "\t", $sample_id, $famid, $abundance, $relative_abundance, "\n" );
	    }
	}
    }
    $self->Shotmap::DB::disconnect_dbh( $dbh );	
    close ABUND;
    return $self;
}

sub build_intersample_abundance_map_flatfile{
    my( $self, $class_id, $abund_param_id ) = @_;
    #dump family abundance data for each sample id to flat file
    my $param_str  = "cid_${class_id}_aid_${abund_param_id}";
    my $outdir     = File::Spec->catdir( $self->project_dir, "output" );
    if( $self->use_db || $self->iterate_output ) {
	$outdir = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}" );
    }
    $outdir = File::Spec->catdir( $outdir, "Abundances" );
    if( ! -d $outdir ){
	die( "I couldn't locate sample flatfile abundance tables in ${outdir}. Are you sure they were built?" );
    }
    my $sample_abund_out  = $outdir . "/Abundance_Map_All_Samples.tab";
    
    open( ABUND, ">$sample_abund_out"  ) || die "Can't open $sample_abund_out for write: $!\n";
    print ABUND join( "\t", "SAMPLE.ID", "FAMILY.ID", "COUNTS", 
		            "ABUNDANCE", "REL.ABUND", "TOT.ABUND", 
		            "CLASS.SEQS", "TOT.SEQS",
		      "\n" );
    opendir( OUTDIR, $outdir ) || die "Can't open $outdir for opendir: $!\n";
    my @files = readdir( OUTDIR );
    closedir OUTDIR;
    #first, we go through all sample abund maps to see what the total unique fams are
    my $fams = (); #hashref
    foreach my $file( @files ){
	next unless( $file =~ m/$param_str/ );
	next if( $file =~ m/\.map$/ ); #in case of a re-run, skip R ouput files
	open( FILE, "${outdir}/${file}" ) || die "Can't open ${outdir}/${file} for read: $!\n";
	while( <FILE> ){
	    next if(  $_ =~ m/^SAMPLE\.ID/ );
	    my @data = split( "\t", $_ );
	    my $fam  = $data[1];
	    $fams->{$fam}++;
	}
	close FILE;
    }
    #now print out the data from each abund map, adding missing families where necessary
    foreach my $file( @files ){
	next unless( $file =~ m/$param_str/ );
	next unless( $file =~ m/sample/ ); #we only want sample, not intersample, files
	open( FILE, "${outdir}/${file}" ) || die "Can't open ${outdir}/${file} for read: $!\n";
	my $has_fam = (); #hashref
	my $sample_id;
	my ( $tot_abund, $class_seqs, $tot_seqs );
	while( <FILE> ){
	    next if(  $_ =~ m/^SAMPLE\.ID/ );
	    print ABUND $_;
	    my @data = split( "\t", $_ );
	    $sample_id = $data[0] unless defined $sample_id;
	    my $fam    = $data[1];
	    if( !defined( $tot_abund ) ){
		$tot_abund = $data[5];
	    }
	    if( !defined( $class_seqs ) ){
		$class_seqs = $data[6];
	    }
	    if( !defined( $tot_seqs ) ){
		$tot_seqs = $data[7];
	    }
	    $has_fam->{$fam}++;
	}
	if( !defined( $tot_abund ) ){
	    die "Couldn't parse total abundance from ${outdir}/${file}\n";
	}
	if( !defined( $tot_seqs) ){
	    die "Couldn't parse total sequences from ${outdir}/${file}\n";
	}
	if( !defined( $class_seqs ) ){
	    die "Couldn't parse class_Seqs from ${outdir}/${file}\n";
	}
	close FILE;
	foreach my $fam( keys( %$fams ) ){
	    next if( defined( $has_fam->{$fam} ) );
	    print ABUND join( "\t", $sample_id, $fam, 0, 0, 0, $tot_abund, $class_seqs, $tot_seqs, "\n" );
	}
    }
    close ABUND;
    return $self;
}

sub delete_prior_project{
    my $self = shift;
    foreach my $sample_alt_id( keys ( %{$self->get_sample_hashref() } ) ){
	my $pid = $self->Shotmap::DB::get_project_by_sample_alt_id( $sample_alt_id );
	$self->Shotmap::Run::clean_project( $pid );
	last;
    }    
    return $self;
}

sub check_prior_analyses{
    my ( $self, $reload ) = @_;
    foreach my $sample_alt_id( keys ( %{$self->get_sample_hashref() } ) ){
	my $sample = $self->Shotmap::DB::get_sample_by_alt_id( $sample_alt_id );
	if( defined( $sample ) ){
	    $self->Shotmap::Notify::warn( "The sample $sample_alt_id already exists in the database under sample_id=" . $sample->sample_id() . "!\n" ) unless $reload;
	    if( $reload ){
		$self->Shotmap::Notify::warn( "Since you specified --reload, I am deleting prior versions of sample_id=" . $sample->sample_id() . " from the database\n" );
		$self->Shotmap::DB::delete_sample( $sample->sample_id() );
	    } else {
		print STDERR ("*" x 80 . "\n");
		print STDERR ("Before proceeding, you must either remove this sample from your project or delete the sample's prior data from the database. You can do this as follows:\n");
		print STDERR (" Option A: Rerun your mcr_handler.pl command, but add the --reload option\n" );
		print STDERR (" Option B: Use MySQL to remove the old data, as follows:\n" );
		print STDERR ("   1. Go to your database server (probably " . $self->db_host() . ")\n");
		print STDERR ("   2. Log into mysql with this command: mysql -u YOURNAME -p   <--- YOURNAME is probably \"" . $self->db_user() . "\"\n");
		print STDERR ("   3. Type these commands in mysql: use ***THE DATABASE***;   <--- THE DATABASE is probably " . $self->db_name() . "\n");
		print STDERR ("   4.                        mysql: select * from samples;    <--- just to look at the projects.\n");
		print STDERR ("   5.                        mysql: delete from samples where sample_id=" . $sample->sample_id . ";    <-- actually deletes this project.\n");
		print STDERR ("   6. Then you can log out of mysql and hopefully re-run this script successfully!\n");
		print STDERR ("   7. You MAY also need to delete the entry from the 'samples' table in MySQL that has the same name as this sample/proejct.\n");
		print STDERR ("   8. Try connecting to mysql, then typing 'select * from samples;' . You should see an OLD project ID (but with the same textual name as this one) that may be preventing you from running another analysis. Delete that id ('delete from samples where sample_id=the_bad_id;'");
		my $mrcCleanCommand = (qq{perl \$Shotmap_LOCAL/scripts/mrc_clean_project.pl} 
				       . qq{ --pid=} . $sample->project_id
				       . qq{ --dbuser=} . $self->db_user()
				       . qq{ --dbpass=} . "PUT_YOUR_PASSWORD_HERE"
				       . qq{ --dbhost=} . $self->db_hostname()
				       . qq{ --ffdb=}   . $self->ffdb()
				       . qq{ --dbname=} . $self->db_name()
				       . qq{ --schema=} . $self->{"schema_name"});
		print STDERR (" Option C: Run mrc_cleand_project.pl as follows:\n" );
		print STDERR ("$mrcCleanCommand\n");
		print STDERR ("*" x 80 . "\n");
		die "Terminating: Duplicate database entry error! See above for a possible solution.";
	    }
	}    
    }
    return $self;
}

sub check_sample_rarefaction_depth{
    my ( $self, $sample_id, $post_rare_reads ) = @_;
    my $bit = 1;
    return $bit if( !defined( $post_rare_reads ) );
    my $reads = $self->Shotmap::DB::get_reads_by_sample( $sample_id );
    if( $reads->count() > $post_rare_reads ){
	warn( "There are not enough reads in sample ${sample_id} to rarefy to a depth of ${post_rare_reads}. I will have to skip all downstream analyses for this sample.\n" );
	$bit = 0;
    }
    return $bit;
}

sub calculate_diversity{
    my( $self, $class_id, $abund_param_id ) = @_; #abundance type is "abundance" or "relative_abundance"
    my $r_lib   = $ENV{"SHOTMAP_LOCAL"} . "/ext/R/";
    my $verbose = $self->verbose;
    #set output directory
    my $outdir = File::Spec->catdir( $self->project_dir, "output/" );
    if( $self->use_db || $self->iterate_output ){
	$outdir         = File::Spec->catdir( $outdir, "class_id_${class_id}", "abund_id_${abund_param_id}");
    }    
    File::Path::make_path($outdir);
    my $metadata_dir;
    if( $self->filter_hits ){
	$metadata_dir = "Metadata_Filtered";
	File::Path::make_path($outdir . "/" . $metadata_dir );
    } else {
	$metadata_dir = "Metadata" ;
	File::Path::make_path($outdir . "/" . $metadata_dir );
    }
    my $scripts_dir     = $self->local_scripts_dir();
    #build a sample metadata table that maps sample_id to metadata properties. dump to file
    my $metadata_table = File::Spec->catfile( $outdir, $metadata_dir, "sample_metadata_tmp.tab" );
    $self->Shotmap::Run::get_project_metadata( $metadata_table );    
    
    #prep the output
    my $abund_dir;
    if( $self->filter_hits ){
	$abund_dir = File::Spec->catdir( $outdir, "Abundances_Filtered" );
    } else {
	$abund_dir = File::Spec->catdir( $outdir, "Abundances" );
    }
    #my $diversity_dir = File::Spec->catdir( $outdir, "Alpha_diversity" );
    #my $families_dir  = File::Spec->catdir( $outdir, "Families" );
    #my $beta_dir      = File::Spec->catdir( $outdir, "Beta_diversity" );
    File::Path::make_path($abund_dir);
    #File::Path::make_path($diversity_dir);
    #File::Path::make_path($families_dir);
    #File::Path::make_path($beta_dir);

    #get the input - abundance dfs
    my @abund_maps = glob( $abund_dir . "/Abundance_Data_Frame*" );
    #make a temporary catted file
    my $tmp_file = $abund_dir . "/tmp_abundance_dfs.tab";
    $self->Shotmap::Run::cat_data_frame_files( \@abund_maps, $tmp_file );

    #are we working with filtered classification maps?
    my $filter = 0;
    if( $self->filter_hits ) {
	$filter = 1;
    }

    #CALCULATE DIVERSITY AND PRODUCE UPDATED METADATA TABLE
    #open output directory that contains per sample diversity data
    #run an R script that groups samples by metadata parameters and identifies differences in diversity distributions
    #produce pltos and output tables
    my $script            = File::Spec->catdir( $scripts_dir, "R", "calculate_diversity.R" );
    my $cmd               = "R --slave --args ${tmp_file} ${outdir} ${metadata_table} $filter $verbose $r_lib < ${script}";
    $self->Shotmap::Notify::notify( "Going to execute the following command:\n${cmd}" );
    Shotmap::Notify::exec_and_die_on_nonzero( $cmd );
#    unlink( $metadata_table ); #this was a tmp file

    ### 5-21-2015: WE NOW LEAVE ALL COMPARATIVE ANALYSES FOR A STANDALONE SCRIPT
    return;

    #ADD BETA-DIVERSITY ANALYSES TO THE ABOVE OR AN INDEPENDENT FUNCTION

    my $n_samples = scalar( @{ $self->get_sample_ids } );
    if( $n_samples < 2 ){
	print "You are processing a single sample, so I will not run the intersample comparative analyses\n";
	return;
    }
    #INTERFAMILY ANALYSIS
    #open directory that contains sample-famid abundance maps for all samples for given class/abundparam id   
    my $family_path_stem = "Inter_Family_Results";
    File::Path::make_path( $outdir . "/${family_path_stem}/" );
    my $family_abundance_prefix = $outdir . "/${family_path_stem}/Family_Tests_cid_${class_id}_aid_${abund_param_id}";
    #my $intrafamily_prefix      = $outdir . "/${family_path_stem}/Family_Comparisons_cid_${class_id}_aid_${abund_param_id}";
    #run an R script that groups samples by metadata parameters and calculates family-level variance w/in and between groups
    #produce plots and output tables for this analysis
    my $test_type      = "wilcoxon.test";
    $script            = File::Spec->catdir( $scripts_dir, "R", "compare_families.R" );
    $cmd               = "R --slave --args ${tmp_file} ${family_abundance_prefix} ${metadata_table} $test_type $verbose $r_lib < ${script}";
    $self->Shotmap::Notify::notify( "Going to execute the following command:\n${cmd}" );
    Shotmap::Notify::exec_and_die_on_nonzero( $cmd );       

    #ORDINATE SAMPLES BY FAMILY RELATIVE ABUNDANCE (e.g. PCA Coordinates)
    #use family abundance tables to conduct a PCA analysis of the samples, producing a loadings table and biplot as output
    my $ordin_path_stem  = "Ordinations";
    File::Path::make_path( $outdir . "/${ordin_path_stem}/" );
    File::Path::make_path( $outdir . "/${ordin_path_stem}/" );
    my $center           = 1;
    my $scale            = 1;
    my $pca_prefix       = $outdir . "/${ordin_path_stem}/Sample_Ordination";
    $script              = File::Spec->catdir( $scripts_dir, "R", "ordinate_samples.R" );    
    $cmd                 = "R --slave --args ${tmp_file} ${pca_prefix} ${metadata_table} ${center} ${scale} $verbose $r_lib < ${script}";
    $self->Shotmap::Notify::notify( "Going to execute the following command:\n${cmd}" );
    Shotmap::Notify::exec_and_die_on_nonzero( $cmd );       
}

sub cat_data_frame_files{
    my( $self, $ar_files2cat, $catted_file ) = @_; 
    my @files_to_cat = @{ $ar_files2cat };
    open( TMP, ">$catted_file" ) || die "Can't open $catted_file for write: $!\n";
    my $big_count = 0; #we only want the header of the first file, so keep track
    foreach my $map( @files_to_cat ){
	open( MAP, $map ) || die "Can't open $map for read: $!\n";
	my $little_count = 0;
	while(<MAP>){
	    #get rid of the headers for files other than the first
	    if( $little_count == 0 &&
		$big_count    == 1 ){
		$little_count = 1;
		next;
	    }
	    print TMP $_;
	}
	close MAP;
	$big_count = 1;
    }
    close TMP;
    return $catted_file;
}

sub count_seqs_in_file{
    my ( $self, $file ) = @_;
    open( FILE, "zcat --force $file |" ) || die "Can't open $file for read: $!\n";
    my $counter = 0;
    while(<FILE>){
	if( $_ =~ m/^>/ ){
	    $counter++;
	}
    }
    close FILE;
    return $counter;       
}

sub parse_file_cols_into_hash{
    my( $self, $file, $key_col_num, $val_col_num, $delimiter ) = @_; #0 index columns in file
    if( !defined( $delimiter ) ){
	$delimiter = "\t";
    }
    my $hash = ();
    open( FILE, $file ) || die "Can't open $file for read: $!\n";
    while( <FILE> ){
	chomp $_;
	my @data = split( $delimiter, $_ );
	$hash->{$data[$key_col_num]} = $data[$val_col_num];
    }
    close FILE;
    return $hash;
}

sub split_sequence_file{
    my $self             = shift;
    my $full_seq_file    = shift;
    my $split_dir        = shift;
    my $basename         = shift;
    my $nseqs_per_split;
    if( $self->remote ){
	$nseqs_per_split  = $self->read_split_size();
    } else {
	my $total_reads;
	if( defined( $self->Shotmap::prerarefy_samples() ) ){
	    $total_reads = $self->Shotmap::prerarefy_samples();
	} else {
	    $total_reads = $self->Shotmap::Run::count_seqs_in_file( $full_seq_file );
	}
	$nseqs_per_split = ceil($total_reads / $self->nprocs()  ); #round up to nearest integer to be sure we get all reads
    }
    #a list of filenames
    my @output_names = ();
    my $compressed   = 0;
    if( $full_seq_file =~ m/\.gz$/ ){
	$compressed = 1;
    }
    if( $compressed ){
	open( SEQS, "zcat $full_seq_file|" ) || die "Can't open $full_seq_file for read in Shotmap::DB::split_sequence_file\n";
    } else {
	open( SEQS, $full_seq_file ) || die "Can't open $full_seq_file for read in Shotmap::DB::split_sequence_file\n";
    }
    my $counter  = 1;
    my $outname  = $basename . $counter . ".fa";
    my $splitout = $split_dir . "/" . $outname;
    open( OUT, ">$splitout" ) || die "Can't open $splitout for write in Shotmap::DB::split_sequence_file_no_bp\n";
    push( @output_names, $outname );
    $self->Shotmap::Notify::print_verbose( "Will dump to split $splitout\n" );
    my $seq_ct   = 0;
    my $header   = ();
    my $sequence = ();
    my $seq_count_across_splits = 0;
    while( <SEQS> ){
	#have we reached the prerarefy sequence count, if that is set?
	if( defined( $self->Shotmap::prerarefy_samples() ) && 
	    $seq_count_across_splits == $self->Shotmap::prerarefy_samples() ){
	    last;
	}	   
	chomp $_;
	if( $_ =~ m/^(\>.*?)(\s|$)/){
	    if( defined( $header ) ){
		my $seqlen = length( $sequence );
		my $check  = $self->Shotmap::Run::check_seqlen_for_print( $seqlen );
		my $header = $self->Shotmap::Run::update_seq_header_w_len( $header, $seqlen ); 
		if( $check ){
		    print OUT "$header\n$sequence\n";
		    $seq_ct++;
		    $seq_count_across_splits++;
		}
		$sequence = ();
	    }
	    $header = $1;
	}
	else{
	    $sequence = $sequence . $_;
	}
	if( eof ) {
	    my $seqlen = length( $sequence );
	    my $check  = $self->Shotmap::Run::check_seqlen_for_print( $seqlen );
	    my $header = $self->Shotmap::Run::update_seq_header_w_len( $header, $seqlen ); 
	    if( $check ){
		print OUT "$header\n$sequence\n";
	    }
	    close OUT;
	    #unless( $self->remote ){
	    Shotmap::Run::gzip_file( $splitout );
	    unlink( $splitout );
	    #}
	} elsif( $seq_ct == $nseqs_per_split  ){	
	    close OUT;
	    #unless( $self->remote ){
		Shotmap::Run::gzip_file( $splitout );
		unlink( $splitout );
	    #}
	    $counter++;
	    my $outname  = $basename . $counter . ".fa";
	    $splitout = $split_dir . "/" . $outname;
	    unless( eof ){
		open( OUT, ">$splitout" ) || die "Can't open $splitout for write in Shotmap::DB::split_sequence_file_no_bp\n";
		push( @output_names, $outname );
		$self->Shotmap::Notify::print_verbose( "Will dump to split $splitout\n" );
		$seq_ct = 0;		
	    }
	}
    }    
    close SEQS;
    return \@output_names;
}

sub check_seqlen_for_print( $$ ){
    my( $self, $seqlen ) = @_;
    my $check = 1;
    if( $seqlen < $self->read_length_filter ){
	$check = 0;
    }
    return $check;
}

sub update_seq_header_w_len($$){
    my( $self, $header, $seqlen ) = @_;
    $header = $header . "-rl${seqlen}";
    return $header;
}

sub build_remote_script{
    my( $self, $type ) = @_;
    my $localScriptDir = $self->local_scripts_dir();
    my $project_dir    = $self->project_dir();

    my $method;
    if( $type eq "orfs" ){
	$method = $self->trans_method;
    } elsif( $type eq "search" || $type eq "parse" ){
	$method = $self->search_method;
    } elsif( $type eq "dbformat" ){
	$method = $self->search_db_fmt_method;
    }
    
    #get options/defaults
    my $cluster_config_file   = $self->cluster_config_file;
    my $remote_project_dir    = $self->remote_project_path;
    my $db_name               = $self->search_db_name($self->search_type);
    my $use_array             = $self->use_array;
    my $use_scratch           = $self->scratch;
    my $db_suffix             = $self->search_db_name_suffix; #only for rapsearch
    my $rapsearch_n_hits      = 1;
    my $hmmer_maxacc          = 0;
    my $cpus                  = 1;
    my $score_threshold       = $self->parse_score;
    my $last_max_multiplicity = 10; #increase to improve sensitivity
    my $metatrans_len_cutoff  = $self->orf_filter_length;
    my $compress              = 1;
    my $scratch_path          = $self->scratch_path;
    my $lightweight           = $self->lightweight;
    my $rpath                 = $self->remote_exe_path;
    my $extra_method          = $self->trans_method; #might need control over var in future

    my $db_size = 0; #only relevant to type = search
    if( $type eq "search" ){
	if( $self->search_type( "blast" ) ){
	    $db_size = $self->Shotmap::DB::get_blast_db_length($db_name);
	} elsif ( $self->search_type( "hmm" ) ){
	    $db_size = $self->Shotmap::DB::get_number_hmmdb_scans( $self->search_db_split_size($self->search_type) );
	}
    }

    my( $compress_str, $hmmeracc_str, $array_str, $scratch_str,
	$light_str,
	);
    if( $compress )    { $compress_str = "--compress";       }
    else               { $compress_str = "--nocompress";     }
    if( $hmmer_maxacc ){ $hmmeracc_str = "--hmmer_maxacc";   }
    else               { $hmmeracc_str = "--nohmmer_maxacc"; }
    if( $use_array )   { $array_str    = "--array";          }
    else               { $array_str    = "--noarray";        }
    if( $use_scratch ) { $scratch_str  = "--scratch";        }
    else               { $scratch_str  = "--noscratch";      }    
    if( $lightweight ) { $light_str    = "--delete-raw";     }
    else               { $light_str    = "--nodelete-raw";   }
    
    my $script       = "$localScriptDir/building_scripts/build_remote_script.pl";
    my $out_script   = "${project_dir}/scripts/";
    if( $type eq "parse" ){
	$out_script .= "run_parse_results.sh";
    } else {
	$out_script .= "run_${method}.sh";
    }
    my $cmd     = "perl $script "  .
	"-t=$type "      .  #search, orfs, dbformat
	"-o=$out_script "          . 
	"-c=$cluster_config_file " . 
	"-m=$method "              .
	"-p=$remote_project_dir "  .
	"--name=$db_name "      .
	"$scratch_str "         .
	"$array_str "           .
	"--suffix=$db_suffix "  .
	"--db-size=$db_size "           .
	"--rapsearch-n-hits=$rapsearch_n_hits "         .
	"$hmmeracc_str "  .
	"--metatrans_len_cutoff=$metatrans_len_cutoff " .
	"$compress_str "    . 
	"--nprocs=${cpus} " . 
	"--scratch-path=${scratch_path} " . 
	"$light_str " .
	"--extra-method=${extra_method}";	
    if( defined( $self->parse_coverage ) ){
	$cmd .= " --coverage=" . $self->parse_coverage . " ";
    }
    if( defined( $self->parse_evalue ) ){
	$cmd .= " --evalue="   . $self->parse_evalue   . " ";
    }
    if( defined( $self->parse_score ) ){
	$cmd .= " --score="    . $self->parse_score    . " ";
    }
    if( defined( $rpath ) ){
	$cmd .= " --rpath="    . $rpath                . " ";
    }
    $self->Shotmap::Notify::print_verbose( "$cmd\n" );
    my $results = Shotmap::Notify::exec_and_die_on_nonzero( $cmd );

    return $out_script;
}

sub run_microbecensus{
    my( $self, $infile, $outfile, $logfile ) = @_;
    #no need to set up a fork, as microbecensus can't run in parallel yet
    my $threads = 8; 
    my $mc_nreads = $self->mc_nreads;
    my $cmd = "run_microbe_census.py -n $mc_nreads -t $threads $infile $outfile > $logfile 2>&1";
    $self->Shotmap::Notify::print( "Waiting for microbecensus to finish..." );
    $self->Shotmap::Notify::print_verbose( "$cmd\n" );
    my $results = IPC::System::Simple::capture("$cmd");                                                                                                                                                                                
    (0 == $EXITVAL) or die("Error executing this command:\n${cmd}\nGot these results:\n${results}\n");                                                                                                                                
    $self->Shotmap::Notify::print( "...microbecensus complete. Proceeding" );
    return $outfile;
}

sub parse_microbecensus{
    my( $self, $sample_alt_id, $ags_output ) = @_;
    open( IN, $ags_output ) || die "can't open AGS file $ags_output for read: $!\n";
    #there should only be two lines in this file!
    while(<IN>){
	chomp $_;
	next if ( $_ =~ m/^reads/ );
	my @data        = split( "\t", $_ );
	my $reads_sampled = $data[0];
	my $read_length   = $data[1];
	my $ags           = $data[2];	
	#set the values
	$self->sample_ags( $sample_alt_id, "read_length", $read_length );
	$self->sample_ags( $sample_alt_id, "ags", $ags );
	$self->sample_ags( $sample_alt_id, "n_reads_sampled", $reads_sampled );
	if( $self->verbose ){
	    $self->Shotmap::Notify::print_verbose( 
		"Sample: $sample_alt_id\n" .
		"ags: "           . $self->sample_ags( $sample_alt_id, "ags" )         . "\n" .
		"read_length: "   . $self->sample_ags( $sample_alt_id, "read_length" ) . "\n" .
		"sampled_reads: " . $self->sample_ags( $sample_alt_id, "n_reads_sampled" ) . "\n"
		);
	}
    }
    close IN;
}

sub get_length_based_cutoff_score($$){
    my( $self, $length ) = @_;
    my $threshold;
    foreach my $ra_range( @{ $self->readlen_map->{"ranges"} } ){
	my( $lower, $upper ) = @{ $ra_range };
	if( $length == $upper ){
	    next; #non-inclusive upper limit. it isn't in this bin, but the next sized bin
	}
	my $is_between = ( sort{ $a <=> $b} $lower, $upper, $length )[1] == $length;
	if( $is_between ){
	    $threshold = $self->readlen_map->{"thresholds"}->{$lower};
	    last;
	}
    }
    if( !defined( $threshold ) ){
	$self->Shotmap::Notify::warn( "Can't determine the threshold for a read of length $length!\n" );
    }
    return $threshold;
}

sub cat_file_array{
    my( $self, $file_array, $outfile ) = @_;
    my $cmd     = "cat " . join( " ", @$file_array ) . " > $outfile";
    my $results = IPC::System::Simple::capture($cmd);
    (0 == $EXITVAL) or die("Error catting files into $outfile" );

    return $outfile;
}


1;
