#!@PERL@ -w

# amdiskflush - transform holding disk into vtape disk
#

package Amanda::DumpFile;

use FileHandle;

sub new {
    my $class = shift;
    my $self = {};

    $self->{"filename"} = $_[0];
    bless $self, $class;

    return $self;
}

sub getHeader {
   my $self = shift;

   my ($fh, $header);
   open($fh,"<",$self->{"filename"})
       or die("Cannot open dumpfile $self->{filename}");
   my $nr = read($fh, $header, 32787);
   close($fh);

   #Make sure we read a block
   return undef unless $nr == 32787;

   # TODO - handle split dumps  (part #) between dir and level
   my ($timestamp,$host,$disk,$level,$comp,$prog) = ($header =~ /^AMANDA: FILE (\d+) (\S+) "?([^"]+)"?  lev (\d+) comp (\S+) program (\S+)/);

   #Make sure we parsed it
   return undef unless defined($timestamp);

   { Date => $timestamp, Host => $host, Disk => $disk, Level => $level,
     Comp => $comp, Program => $prog };
}

package main;

use strict;
use warnings;

use Amanda::Config qw( :init :getconf);
use Amanda::Disklist;
use Amanda::Logfile qw( :logtype_t log_add log_add_full );
use Amanda::Util qw( :constants match_datestamp quote_string );
use File::Basename;
use Getopt::Long;
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday);

my $USE_VERSION_SUFFIXES='@USE_VERSION_SUFFIXES@';
my $suf = '';
if ( $USE_VERSION_SUFFIXES =~ /^yes$/i ) {
        $suf='-@VERSION@';
}

sub Usage {
    print STDERR <<END;
Usage: $0 [--config] <config>

Transform holding disk into vtape disk.  This can be used on disk based
vtapes along with "amdump --no-taper" to perform backups directly to
the final disk location.
END
    exit 1;
}

my $opt_version;
my $opt_config          = undef;

GetOptions('version'            => \$opt_version,
           'config=s'           => \$opt_config)
or Usage();

if (defined $opt_version) {
    print "amdiskflush-" . $Amanda::Constants::VERSION , "\n";
    exit 0;
}

unless(defined($opt_config)) {
    if (@ARGV == 1) {
        $opt_config = $ARGV[0];
    } else {
        Usage();
    }
}

Amanda::Util::setup_application("amflush", "server", $CONTEXT_DAEMON, "amanda", "amanda");

my $starttime = gettimeofday();

config_init($CONFIG_INIT_EXPLICIT_NAME, $opt_config);
my ($cfgerr_level, @cfgerr_errors) = config_errors();
if ($cfgerr_level >= $CFGERR_WARNINGS) {
    config_print_errors();
    if ($cfgerr_level >= $CFGERR_ERRORS) {
        die("amdiskflush$suf: errors processing config file");
    }
}

Amanda::Util::finish_setup($RUNNING_AS_DUMPUSER);

# Get the holding disk directories
my @hddirs;
for my $hdname (@{getconf($CNF_HOLDINGDISK)}) {
    my $cfg = lookup_holdingdisk($hdname);
    next unless defined $cfg;

    my $dir = holdingdisk_getconf($cfg, $HOLDING_DISKDIR);
    next unless defined $dir;
    next unless -d $dir;
    push(@hddirs, $dir);
}

# Add date shell wildcard match to hddirs
map { $_ .= '/[1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' } @hddirs;

# Make sure we have some holding disk files to flush
my $hdfindcmd = 'find ' . join(" ", @hddirs) . ' -name \*.\[0-9\]';
my $hdfiles = `$hdfindcmd 2>/dev/null`;
if ($hdfiles eq "") {
   die("amdiskflush$suf: No holding disk files found in " .
       join(" ", @hddirs) . "\n");
}

# Get the vtape directory and make sure we are using the file: driver
my $vtapedir = getconf($CNF_TAPEDEV);
if ($vtapedir) {
   $vtapedir =~ s/^file:// or
      die("amdiskflush$suf: Not using file: driver for tapedev: $vtapedir"); 
} else {
    my $changer = getconf($CNF_TPCHANGER);
    my $cfg = lookup_changer_config($changer);
    $vtapedir = changer_config_getconf($cfg,$CHANGER_CONFIG_TPCHANGER);
    $vtapedir =~ s/^chg-disk:// or
        die("amdiskflush$suf: Not using chg-disk: driver for tpchanger: $vtapedir"); 
}

# Get the log directory
my $logdir = getconf($CNF_LOGDIR);

# Make sure no other server is running
#if (-f "$logdir/log") {
   #die("amdiskflush$suf: Another Amanda server is running or amcleanup must be run\n");
#}

# Make sure that the vtape is labeled
defined(my $labelfile = <$vtapedir/data/00000.*>)
  or die("amdiskflush$suf: Cannot find vtape label in $vtapedir/data/");

# Date label
my $timestamp = strftime("%Y%m%d%H%M%S", localtime());

# Open our log file
$timestamp = Amanda::Logfile::make_logname("amflush", $timestamp);
my $logfile = Amanda::Logfile::get_logname();

my $logfh = Amanda::Logfile::open_logfile($logfile)
   or die "cannot open logfile $logfile: $!";

$cfgerr_level = Amanda::Disklist::read_disklist();
if ($cfgerr_level >= $CFGERR_ERRORS) {
    die("errors processing disklist");
}
# Output DISK records for each DLE
foreach my $dle (Amanda::Disklist::all_disks()) {
   log_add($L_DISK, $dle->{"host"}->{"hostname"} . " " . quote_string($dle->{name}));
}

# Start record 
log_add($L_START, "date $timestamp");

# Extract the tape label from the tape start filename
my ($tapelabel) = ($labelfile =~ /0000\.(.*)/);

# Log "taper start"
log_add_full($L_START, "taper", "datestamp $timestamp label $tapelabel tape 0");

# Update the tape list
my $tapelist = getconf($CNF_TAPELIST);
my @tapelist;
my ($tapeentry, $fh);
# Read the tapelist, saving the entry for this tape separately from the rest
open($fh, "<", "$tapelist") or die("amdiskflush$suf: Cannot read tapelist $tapelist");
while (<$fh>) {
  if (/ $tapelabel /) {
    $tapeentry = $_;
  } else {
    push(@tapelist,$_);
  }
}
close($fh);
# Backup the tapelist
rename("$tapelist","${tapelist}.yesterday");
# Update the date for the tape
$tapeentry =~ s/^\d+/$timestamp/;
# Stick it at the top of the list
unshift(@tapelist,$tapeentry);
# Write the tapelist back out
open($fh, ">", "$tapelist") or die("amdiskflush$suf: Cannot write tapelist $tapelist");
print $fh @tapelist;
close($fh);

# Remove any existing tape files
unlink(<$vtapedir/data/*>);

# Create the tape label
open($fh,">",$labelfile) or die("amdiskflush$suf: Cannot write labelfile $labelfile");
print $fh pack("a32768","AMANDA: TAPESTART DATE $timestamp TAPE $tapelabel\n014\n");
close($fh);

my $infodir = getconf($CNF_INFOFILE);

# Process the holding disk files
my $filecount = 1;
my $filecountstr = sprintf("%05d",$filecount);
my $totalkb = 0;
foreach my $hdfile (split('\n',$hdfiles)) {
  my $filestarttime = gettimeofday();
  my $filename = basename($hdfile);
  my ($dumpdate) = ($hdfile =~ m,/(\d{14}),);

  # Get the number of blocks
  my $bytes = (stat($hdfile))[7];
  my $kb = $bytes/1024;

  # Get the header from the holding file
  my $amdumpfile = Amanda::DumpFile->new($hdfile);
  my $header = $amdumpfile->getHeader();

  if (defined($header)) {
    # Move the holding disk file to the vtape dir
    rename($hdfile,"$vtapedir/data/${filecountstr}.${filename}");

    # Update info file
    my $infodiskname = $header->{"Disk"};
    $infodiskname =~ s,/,_,g;
    my $infofh;
    open($infofh, "<", "$infodir/$header->{Host}/$infodiskname/info")
       or die("amdiskflush$suf: Cannot open $infodir/$header->{Host}/$infodiskname/info");
    my @info = <$infofh>;
    close($infofh);

    map { s/^(stats: $header->{Level} \d+ \d+ \d+ \d+)(.*)/$1 $filecount $tapelabel/ } @info;
 
    open($infofh, ">", "$infodir/$header->{Host}/$infodiskname/info")
       or die("amdiskflush$suf: Cannot write $infodir/$header->{Host}/$infodiskname/info");
    print $infofh @info;
    close($infofh); 

    # Log output
    my $fileflushtime = gettimeofday() - $filestarttime;
    log_add_full($L_PART, "taper", sprintf("%s %d %s %s %d 1/-1 %d [sec %.6f bytes %d kps %.6f orig-kb %d]",$tapelabel,$filecount,$header->{"Host"},quote_string($header->{"Disk"}),$dumpdate,$header->{"Level"},$fileflushtime,$bytes,$kb/$fileflushtime,$kb));
    log_add_full($L_DONE, "taper",  sprintf("%s %s %d %d %d [sec %.6f bytes %d kps %.6f orig-kb %d]",$header->{"Host"},quote_string($header->{"Disk"}),$dumpdate,1,$header->{"Level"},$fileflushtime,$bytes,$kb/$fileflushtime,$kb));

    # Increment out filecounter
    $filecountstr = sprintf("%05d",++$filecount);
    $totalkb += $kb;
  } else {
    print STDERR "Could not read header for $hdfile, skipping...\n";
  }
}

# Delete the holding disk date dirs
rmdir(<@hddirs>);

# Taper totals for amreport
log_add_full($L_INFO, "taper", "tape $tapelabel kb $totalkb fm " . ($filecount-1) . " [OK]");

# So amreport thinks the run finished properly
log_add_full($L_FINISH, "driver", sprintf("date %d time %.3f",$timestamp,gettimeofday() - $starttime));

# Record our PID as done
log_add($L_INFO, "pid-done $$");

# Close the log
Amanda::Logfile::close_logfile($logfh);

# Send logs
system("@sbindir@/amreport$suf --from-amdump -l $logfile $opt_config");

# Roll the log file
system("@amlibexecdir@/amlogroll$suf $opt_config");

Amanda::Util::finish_application();
