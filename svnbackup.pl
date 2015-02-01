#!/usr/bin/perl

#############################################################################
# svnbackup.pl  version .10-beta                                             #
#                                                                           #
# History and information:                                                  #
# http://www.ghostwheel.com/merlin/Personal/notes/svnbackuppl/              #
#                                                                           #
# Synapsis:                                                                 #
#   This script allows you to make incremental backups of a SVN repository. #
#   Unlike 'hotcopy' backups, these can efficiently be backed up via        #
#   rsync or duplicity.                                                     #
#                                                                           #
# Usage:                                                                    #
#   svnbackup.pl REPODIR BACKUPDIR                                          #
#                                                                           #
# Automatic recovery:                                                       #
#   Use svnrestore.pl to automatically process the backup log and .svnz     #
#   files too re-create a new SVN repository.                               #
#                                                                           #
# Manual Recovery:                                                          #
#   - use 'svnadmin create' to create a new repository.                     #
#   - use 'svnadmin load' to restore all of the backup files, in order.     #
#   ie:                                                                     #
#      svnadmin create /tmp/test                                            #
#      gzcat 0-100.svnz | svnadmin load /tmp/test                           #
#      gzcat 101-110.svnz | svnadmin load /tmp/test                         #
#                                                                           #
#  To do:                                                                   #
#    - Add better activity messages                                         #
#    - Create svnrestore.pl which will read the .log file from a backup     #
#      directory and automagically restore the entire backup                #
#                                                                           #
#############################################################################
#                                                                           #
# Version .10-beta changes                                                  #
# - Added locating utilities from within PATH so that this script should    #
#   run without modification on most systems.                               #
#                                                                           #
# Version .9-beta changes                                                   #
# - Added using /tmp/svnbackup-BACKUPDIR.lock as a lock-file to prevent     #
#   concurrent execution of svnbackup.pl or svnrestore.pl which could       #
#   corrupt backups and prevent complete restores.                          #
# - Added error handling in case the external call to svnadmin fails.       #
#                                                                           #
#                                                                           #
#                                                                           #
#############################################################################


## * Copyright (c) 2008, Chris O'Halloran
## * All rights reserved.
## *
## * Redistribution and use in source and binary forms, with or without
## * modification, are permitted provided that the following conditions are met:
## *     * Redistributions of source code must retain the above copyright
## *       notice, this list of conditions and the following disclaimer.
## *     * Redistributions in binary form must reproduce the above copyright
## *       notice, this list of conditions and the following disclaimer in the
## *       documentation and/or other materials provided with the distribution.
## *     * Neither the name of Chris O'Halloran nor the
## *       names of any contributors may be used to endorse or promote products
## *       derived from this software without specific prior written permission.
## *
## * THIS SOFTWARE IS PROVIDED BY Chris O'Halloran ''AS IS'' AND ANY
## * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
## * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
## * DISCLAIMED. IN NO EVENT SHALL Chris O'Halloran BE LIABLE FOR ANY
## * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
## * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
## * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
## * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
## * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
## * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


use File::Path;


## Here is an example of how to specify a location for a particular utility.  
#$UtilLocation{'gunzip'} = '/usr/bin/gunzip';

## Locate the following utilities for use by the script
@Utils = ('svnlook', 'svnadmin', 'gzip', 'gunzip');
foreach $Util (@Utils) 
	{
	if ($UtilLocation{$Util} && (!-f $UtilLocation{$Util}) )
		{
		die ("$Util path is specified ($UtilLocation{$Util}) but is incorrect.\n");
		}
	elsif ( !($UtilLocation{$Util} = `which $Util`) )
		{
		die ("Unable to fine $Util in the current PATH.\n");
		}
	$UtilLocation{$Util} =~ s/[\n\r]*//g;
	print "$Util - $UtilLocation{$Util}\n" if $DEBUG;
	}


## Change to 1 if you want debugging messages.
$DEBUG=0;



## Verify the number of arguments supplied matches the requirements, and prints a usage statement
## if necessary.
if ( @ARGV < 2 )
	{
	print "Insufficient arguments.\n";
	print "Usage:  svnbackup.pl REPODIR BACKUPDIR\n\n";
	exit;
	}
$REPODIR = $ARGV[0];
$BACKUPDIR = $ARGV[1];
print "REPODIR: $REPODIR\n" if $DEBUG;
print "BACKUPDIR: $BACKUPDIR\n" if $DEBUG;

($LOCKSUFFIX = $BACKUPDIR) =~ s/\//_/g;
open(LOCK, ">/tmp/svnbackup-$LOCKSUFFIX.lock");
flock(LOCK,2);


## This performs two functions at once, one it verifies that the supplied REPODIR is valid AND
## it reads the ID for the most recent check-in
($LASTCHECKIN = `$UtilLocation{'svnlook'} youngest $REPODIR 2>&1`) =~ s/[\n\r]//g;
print "LASTCHECKIN: $LASTCHECKIN\n" if $DEBUG;
if ( $LASTCHECKIN =~ m/^[0-9]+/)
	{
	}
else
	{
	print "ABORT:  $REPODIR is not a valid SVN repository.\n\n";
	&unlockexit;
	}

## If $LASTCHECKIN is 0, then this is an empty repository and there is no reason to back it up.
if ($LASTCHECKIN == 0)
	{
	print "ABORT:  $REPODIR is an empty repository with no check-ins.\n\n";
	&unlockexit;
	}



## Check to see if the specified backup directory is valid, matches the repository to be backed up,
## and then read information about the check-ins that have been backed up if all checks out.
if ( -d $BACKUPDIR )
	{
	## Backup directory exists, so let's see if there is a svnbackup.id created by this script
	if ( -f "$BACKUPDIR/svnbackup.id" )
		{
		## svnbackup.id exists, so lets read the contents and see if it matches the repo
		($SVNBACKUP = `cat $BACKUPDIR/svnbackup.id`) =~ s/[\n\r]//g;
		print "SVNBACKUP: $SVNBACKUP\n" if $DEBUG;
		if ( $SVNBACKUP eq $REPODIR )
			## Since the repo and the backup match, we need to read information about the last backup.
			{
			## Check to see if there is a backup log, and if there is read the last backed up check-in
			## and use that information to set LASTBACKUP and FIRSTTOBACKUP;
			if ( -f "$BACKUPDIR/svnbackup.log" )
				{
				open(READLOG, "$BACKUPDIR/svnbackup.log") || die("Unable to open $BACKUPDIR/svnbackup.log for reading.\n");
				while ( ($LOGLINE = <READLOG>) =~ s/[\n\r]//g)
					{
					if ( $LOGLINE =~ m/([0-9]+)\t([0-9]+)\t(.+)$/ )
						{
						$STARTID = $1;
						$STOPID = $2;
						$BACKUPILENAME = $3;
						print "LOGLINE: $STARTID\t$STOPID\t$BACKUPILENAME\n" if $DEBUG;
						}
					}
				close(READLOG);
				$FIRSTTOBACKUP = $STOPID +1;
				$DUMPFLAGS .= " --incremental ";
				}
			else
				{
				## svnbackup.log does not exist, so $FIRSTTOBACKUP automatically is 0
				print "DEBUG:  $BACKUPDIR/svnbackup.log does not exist\n" if $DEBUG;
				}
				print "FIRSTTOBACKUP: $FIRSTTOBACKUP\n" if $DEBUG;

			}
		else
			{
    		print "Existing backup in $BACKUPDIR (repo $SVNBACKUP) does not match repository $REPODIR.\n\n";
    		&unlockexit;
			}
		}
	}
else
	## The backup directory passed to this script does not exist, so we need to create it.
	{
	eval { mkpath($BACKUPDIR) };
  	if ($@) 
  		{
    	print "Couldn't create $BACKUPDIR: $@\n\n";
    	&unlockexit;
  		}
  	
	}
	
## Write the svnbackup.id file, if it doesn't already exist.
if ( !(-f "$BACKUPDIR/svnbackup.id") )
	{
	## svnbackup.id did not exist, so let's create it and write the path for the repo passed to this script
	`echo $REPODIR > $BACKUPDIR/svnbackup.id`;
	}
	
## If $FIRSTTOBACKUP hasn't been defined from the log file, it's automatically a 0
if ( !(defined($FIRSTTOBACKUP)) )
	{
	$FIRSTTOBACKUP = 0;
	}


####  Here is where we start the actual backup process.  If the starting ID is 0 we do a full backup
####  and if it is anyting other than 0 we use the --incremental flag.

## Set the filename for this backup set:
$FILENAME = "$FIRSTTOBACKUP-$LASTCHECKIN.svnz";

## Perform the backup, if the log does not indicate it has already been backed up
if ($FIRSTTOBACKUP <= $LASTCHECKIN) 
	{
	print "$UtilLocation{'svnadmin'} dump -r $FIRSTTOBACKUP:$LASTCHECKIN $DUMPFLAGS $REPODIR | $UtilLocation{'gzip'} -c > $BACKUPDIR/$FILENAME\n" if $DEBUG;
	$status = system("$UtilLocation{'svnadmin'} dump -r $FIRSTTOBACKUP:$LASTCHECKIN $DUMPFLAGS $REPODIR | $UtilLocation{'gzip'} -c > $BACKUPDIR/$FILENAME");
	if ( $status != 0) {
		## We have had a problem with svnadmin, and need to abort.  We should clean up before exiting, and exit before updating the log.
		unlink("$BACKUPDIR/$FILENAME");
		print "ERROR:  svnadmin command execution failed.\n";
		&unlockexit;
		}
	open(WRITELOG, ">>$BACKUPDIR/svnbackup.log");
	print WRITELOG "$FIRSTTOBACKUP\t$LASTCHECKIN\t$BACKUPDIR/$FILENAME\n";
	close(WRITELOG);
	}
else
	{
	print "The backup is current, so there is nothing to do.\n\n";
	}

## All done, so let's invoke the lock file removal and exit routine.
&unlockexit;


	
sub unlockexit {
	flock(LOCK,8);
	close(LOCK);
	unlink("/tmp/svnbackup-$LOCKSUFFIX.lock");
	exit;
	}