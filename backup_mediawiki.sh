#!/bin/bash
#
# Summary: Backup MediaWiki instances including databases, files, HTML pages.
#
# Author:
# Meng Lu <lumeng.dev@gmail.com>
# (adapated from Sam Wilson https://github.com/samwilson/MediaWiki_Backup)
#
# TODO:
# * Use *.7z (7z) format instead of *.bz2 format (pbzip2)
#
# History:
#
# * 20140914: added ability to automatically backup Mediawiki
# instances configured to use SQLite databases instead of MySQL
# databases
#
# * 20140914: added ability to automatically write a log entry into a
# log file into the backup path each time the script is run
#
# * 20140913: let a backup instance be created in a sub-directory
# under the backup path specified as -d as there are in general
# several resultant backup files created for one backup operation.
#
# * 20140913: let a backup operation also backup the installation
# directory of the MediaWiki instance, so LocalSettings.php and
# extensions are backed up too.  TODO: this obviously is more than
# what's necessary.
#
# * 201409: adapted from Sam Wilson
# https://github.com/samwilson/MediaWiki_Backup
#
################################################################################
## Output command usage
function usage {
    local NAME=$(basename $0)
    echo "Usage: $NAME -d backup/dir -w installation/dir"
}

function versioncheck {
    echo "Version check: php 5.3+"
}

################################################################################
## Output command usage
function logprint {
    if hash tee 2>/dev/null; then
        echo "$@" 2>&1 | tee $LOG
    else
        echo "$@"
    fi
}

################################################################################
## Get and validate CLI options
function get_options {
    while getopts 'd:w:' OPT; do
        case $OPT in
            d) BACKUP_DIR=$OPTARG;;
            w) INSTALL_DIR=$OPTARG;;
        esac
    done

	## Check versions of executable programs
    if hash /usr/local/php54/bin/php 2>/dev/null; then
	    PHP_BIN=/usr/local/php54/bin/php
	elif hash /usr/local/php53/bin/php 2>/dev/null; then
	    PHP_BIN=/usr/local/php53/bin/php
	else
        PHP_BIN=php
		versioncheck; exit 1;
	fi
		

    ## Check BKP_DIR
    if [ -z $BACKUP_DIR ]; then
        echo "Please provide a backup directory with -d" 1>&2
        usage; exit 1;
    fi
    if [ ! -d $BACKUP_DIR ];
	then
        mkdir --parents $BACKUP_DIR;
        if [ ! -d $BACKUP_DIR ]; then
            echo -n "Backup directory $BACKUP_DIR does not exist" 1>&2
            echo " and could not be created" 1>&2
            exit 1;
		fi
	else
	    BACKUP_DIR=$(cd $BACKUP_DIR; pwd -P)
		LOG="$BACKUP_DIR/mediawiki_backup.log"
    fi

    ## Check WIKI_WEB_DIR
    if [ -z $INSTALL_DIR ]; then
        echo "Please specify the wiki directory with -w" 1>&2
        usage; exit 1;
    fi
    if [ ! -f $INSTALL_DIR/LocalSettings.php ]; then
        echo "No LocalSettings.php found in $INSTALL_DIR" 1>&2
        exit 1;
    fi
    INSTALL_DIR=$(cd $INSTALL_DIR; pwd -P)
    logprint "Backing up wiki installed in $INSTALL_DIR"$(date)

    # start backing up
    logprint "Backing up to $BACKUP_DIR "

	BACKUP_FILENAME_PREFIX="backup_"$(date +%Y%m%d)
	BACKUP_SUBDIR="$BACKUP_DIR/$BACKUP_FILENAME_PREFIX"
    if [ ! -d $BACKUP_SUBDIR ]; then
        mkdir --parents $BACKUP_SUBDIR;
        if [ ! -d $BACKUP_SUBDIR ]; then
            echo -n "Backup sub-directory $BACKUP_SUBDIR does not exist" 1>&2
            echo " and could not be created" 1>&2
            exit 1;
        fi
    fi
    BACKUP_SUBDIR=$(cd $BACKUP_SUBDIR; pwd -P)
    logprint "Backing up to $BACKUP_SUBDIR"

}


## Set options for tar to use bz2 format for high compression rate
## and pbzip2 for paralellism
if hash pbzip2 2>/dev/null; then
	ZIP_PROGRAM=pbzip2
    TAR_OPTIONS="--use-compress-program=pbzip2"
	ZIP_FILENAME_EXT=".bz2"
	TAR_FILENAME_EXT=".tar.bz2"
elif has pigz 2>/dev/null; then
	ZIP_PROGRAM=pigz
    TAR_OPTIONS="--use-compress-program=pigz"
	ZIP_FILENAME_EXT=".gz"
	TAR_FILENAME_EXT=".tar.gz"
else
	ZIP_PROGRAM=gzip
    TAR_OPTIONS="--use-compress-program=gzip"
	ZIP_FILENAME_EXT=".gz"
	TAR_FILENAME_EXT=".tar.gz"
fi



################################################################################
## Parse required values out of LocalSetttings.php
function get_localsettings_vars {
    LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

	DB_TYPE=`grep '^\$wgDBtype' $LOCALSETTINGS  | cut -d\" -f2`

	DB_NAME=`grep '^\$wgDBname' $LOCALSETTINGS  | cut -d\" -f2`

	if [ "$DB_TYPE" != 'sqlite' ]; then
		logprint "The MediaWiki instance uses MySQL database, backup using mysqldump"
		DB_HOST=`grep '^\$wgDBserver' $LOCALSETTINGS | cut -d\" -f2`
		DB_USER=`grep '^\$wgDBuser' $LOCALSETTINGS  | cut -d\" -f2`
		DB_PASS=`grep '^\$wgDBpassword' $LOCALSETTINGS  | cut -d\" -f2`
		logprint "Logging in as $DB_USER to $DB_HOST to backup $DB_NAME"

		# Try to extract default character set from LocalSettings.php
		# but default to binary
		DBTableOptions=$(grep '$wgDBTableOptions' $LOCALSETTINGS)
		CHARSET=$(echo $DBTableOptions | grep 'CHARSET' | sed -E 's/.*CHARSET=([^"]*).*/\1/')
		if [ -z $CHARSET ]; then
			CHARSET="binary"
		fi

		logprint "Character set in use: $CHARSET"
	else
		logprint "The MediaWiki instance uses SQLite database, backup using file copying and compressing"
    	SQLITE_DATA_DIR=`grep '^\$wgSQLiteDataDir' $LOCALSETTINGS  | cut -d\" -f2`
        SQLITE_FILE=$SQLITE_DATA_DIR/$DB_NAME".sqlite"
	fi
}

################################################################################
## Add $wgReadOnly to LocalSettings.php
## Kudos to http://www.mediawiki.org/wiki/User:Megam0rf/WikiBackup
function toggle_read_only {
    local MSG="\$wgReadOnly = 'Backup in progress.';"
    local LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    # If already read-only
    grep "$MSG" "$LOCALSETTINGS" > /dev/null
    if [ $? -ne 0 ]; then

        logprint "Entering read-only mode"
        grep "?>" "$LOCALSETTINGS" > /dev/null
        if [ $? -eq 0 ];
        then
            sed -i "s/?>/\n$MSG/ig" "$LOCALSETTINGS"
        else
            echo "$MSG" >> "$LOCALSETTINGS"
        fi 

    # Remove read-only message
    else

        logprint "Returning to write mode"
        sed -i "s/$MSG//ig" "$LOCALSETTINGS"

    fi
}


################################################################################
## Add $wgReadOnly to LocalSettings.php
function toggle_read_only_on {
    local MSG="\$wgReadOnly = 'Backup in progress.';"
    local LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    # If already read-only
    grep "$MSG" "$LOCALSETTINGS" > /dev/null
    if [ $? -ne 0 ]; then

        logprint "Entering read-only mode"
        grep "?>" "$LOCALSETTINGS" > /dev/null
        if [ $? -eq 0 ];
        then
            sed -i "s/?>/\n$MSG/ig" "$LOCALSETTINGS"
        else
            echo "$MSG" >> "$LOCALSETTINGS"
        fi 
    fi
}


################################################################################
## Add $wgReadOnly to LocalSettings.php
## Kudos to http://www.mediawiki.org/wiki/User:Megam0rf/WikiBackup
function toggle_read_only_off {
    local MSG="\$wgReadOnly = 'Backup in progress.';"
    local LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    grep "$MSG" "$LOCALSETTINGS" > /dev/null
    if [ ! $? -ne 0 ]; then
        # If already read-only, remove read-only configuration
        logprint "Returning to write mode"
        sed -i "s/$MSG//ig" "$LOCALSETTINGS"
    fi
}


################################################################################
## Dump database to SQL
## Kudos to https://github.com/milkmiruku/backup-mediawiki
function export_sql {
    SQLFILE=$BACKUP_PREFIX"-database.sql"$ZIP_FILENAME_EXT
    logprint "Dumping database to $SQLFILE"
    nice -n 19 mysqldump --single-transaction \
        --default-character-set=$CHARSET \
        --host=$DB_HOST \
        --user=$DB_USER \
        --password=$DB_PASS \
        $DB_NAME | $ZIP_PROGRAM -9 > $SQLFILE

    # Ensure dump worked
    MySQL_RET_CODE=$?
    if [ $MySQL_RET_CODE -ne 0 ]; then
        ERR_NUM=3
        echo "MySQL Dump failed! (return code of MySQL: $MySQL_RET_CODE)" 1>&2
        exit $ERR_NUM
    fi
}

################################################################################
## Backup *.sqlite file
function backup_sqlite {
#    SQLITE_FILE_BACKUP=$BACKUP_PREFIX"-database.sqlite"$ZIP_FILENAME_EXT
#    logprint "Dumping database $SQLITE_FILE to $SQLITE_FILE_BACKUP"
#	if [ -f $SQLITE_FILE ]; then
#        cd "$SQLITE_DATA_DIR"
#		$ZIP_PROGRAM -9 "$SQLITE_FILE_BACKUP" $DB_NAME".sqlite" 
#		#tar --use-compress-program=pbzip2 -cf "$SQLITE_FILE_BACKUP" $DB_NAME".sqlite"
#	else
#		echo "SQLite database file $SQLITE_FILE does not exist!" 1>&2
#		exit 1
#	fi

	# dump using the MediaWiki maitenance script
    SQLITE_FILE_BACKUP=$BACKUP_PREFIX"-database.sqlite"$ZIP_FILENAME_EXT
    SQLITE_FILE_BACKUP_TMP=$BACKUP_PREFIX"-database__tmp.sqlite"
    cd "$INSTALL_DIR/maintenance"
	$PHP_BIN sqlite.php --backup-to $SQLITE_FILE_BACKUP_TMP
	cd $BACKUP_SUBDIR
    $ZIP_PROGRAM -9 $SQLITE_FILE_BACKUP_TMP > $SQLITE_FILE_BACKUP
	if [ -f $SQLITE_FILE_BACKUP_TMP -a -f $SQLITE_FILE_BACKUP ]; then
		rm $SQLITE_FILE_BACKUP_TMP
	else
        echo "SQLite Dump failed! (return code of SQLite: $SQLite_RET_CODE)" 1>&2
	fi
}


################################################################################
## XML
## Kudos to http://brightbyte.de/page/MediaWiki_backup
function export_xml {
    XML_DUMP=$BACKUP_PREFIX"-pages.xml"$ZIP_FILENAME_EXT
    logprint "Exporting XML to $XML_DUMP"
    cd "$INSTALL_DIR/maintenance"
    $PHP_BIN -d error_reporting=E_ERROR dumpBackup.php --quiet --full \
    | $ZIP_PROGRAM -9 > "$XML_DUMP"
}

################################################################################
## Export the images directory
function export_images {
    IMG_BACKUP=$BACKUP_PREFIX"-images"$TAR_FILENAME_EXT
    logprint "Compressing images to $IMG_BACKUP"
    cd "$INSTALL_DIR"
    tar --use-compress-program=pbzip2 -cf "$IMG_BACKUP" images
}

################################################################################
## Back up the entire MediaWiki installation directory, which includes potentially
## customized configuration file LocalSettings.php, extensions, etc.
function backup_mwdir {
    MWDIR_BACKUP=$BACKUP_PREFIX"-mwdir"$TAR_FILENAME_EXT
    logprint "Compressing MediaWiki installation directory to $MWDIR_BACKUP"
	INSTALL_DIR_PARENT="$(dirname "$INSTALL_DIR")"
	INSTALL_DIR_BASENAME="$(basename "$INSTALL_DIR")"
    if [ -d $INSTALL_DIR_PARENT ];
	then
        cd "$INSTALL_DIR_PARENT"
	    tar --use-compress-program=pbzip2 -cf "$MWDIR_BACKUP" "$INSTALL_DIR_BASENAME"
	else
        logprint "$INSTALL_DIR_PARENT is not a valid path, fail to backup MediaWiki dir"
	fi
}


################################################################################
## Main

# Preparation
get_options $@
get_localsettings_vars
toggle_read_only_on

# Backup
BACKUP_PREFIX=$BACKUP_SUBDIR/$BACKUP_FILENAME_PREFIX
if [ "$DB_TYPE" != 'sqlite' ]; then
    export_sql
else
	backup_sqlite
fi
export_xml
export_images
backup_mwdir
 
toggle_read_only_off

## End main
################################################################################
