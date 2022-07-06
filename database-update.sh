#!/bin/bash

# Config file
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
	DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
	SOURCE="$( readlink "$SOURCE" )"
	[[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done

DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

CONFIG=${DIR%/*/*/*}

# Import config settings
source "$CONFIG/.env"

# Local config
LOCAL_DATABASE_HOST=$DB_HOST
LOCAL_DATABASE_NAME=$DB_NAME
LOCAL_DATABASE_USER=$DB_USER
LOCAL_DATABASE_PASS=$DB_PASSWORD

# Remote config
REMOTE_DATABASE_HOST=$REMOTE_DB_HOST
REMOTE_DATABASE_NAME=$REMOTE_DB_NAME
REMOTE_DATABASE_USER=$REMOTE_DB_USER
REMOTE_DATABASE_PASS=$REMOTE_DB_PASSWORD

IGNORE_TABLES=$SYNC_IGNORE_TABLES
IGNORE_ACTIVE_PLUGINS=$SYNC_IGNORE_ACTIVE_PLUGINS

# Current timestamp
CURRENT_TIME=$(date "+%Y.%m.%d-%H.%M.%S")

# Create directory to store dumps
mkdir -p "$CONFIG/dumps"

echo Backing up local database: $LOCAL_DATABASE_NAME
mysqldump -v -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS $LOCAL_DATABASE_NAME > "$CONFIG/dumps/local-database-$CURRENT_TIME.sql"

# As we're going to delete the table, add the existing versions of "skipped tables" to the script so they aren't empty when we reimport/recreate
for t in $(mysql -NBA -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS $LOCAL_DATABASE_NAME -e 'show tables') 
do 
	# Clear any white space
	t=`echo $t`
	if [[ "$IGNORE_TABLES" == *"$t"* ]]; then
		# Retain originals for skipped tables
		echo "RETAIN TABLE: \"$t\""
		mysqldump -v -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS $LOCAL_DATABASE_NAME $t --skip-comments --no-tablespaces --quick --max_allowed_packet=512M >> "$CONFIG/dumps/remote-database-$CURRENT_TIME.sql"
	fi
done

# Delete local database
echo Dropping local database: $LOCAL_DATABASE_NAME
mysqladmin -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS drop $LOCAL_DATABASE_NAME -f

# Create local database
echo Creating local database: $LOCAL_DATABASE_NAME
mysqladmin -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS create $LOCAL_DATABASE_NAME

# Check for database connections
if mysql -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS -e 'use '"$LOCAL_DATABASE_NAME" && mysql -h $REMOTE_DATABASE_HOST -u $REMOTE_DATABASE_USER -p$REMOTE_DATABASE_PASS -e 'use '"$REMOTE_DATABASE_NAME"; then

	# Download everything from database in one shot
	# echo Exporting database \'$REMOTE_DATABASE_NAME\' from remote server: $REMOTE_DATABASE_HOST
	# mysqldump -v -h $REMOTE_DATABASE_HOST -u $REMOTE_DATABASE_USER -p$REMOTE_DATABASE_PASS $REMOTE_DATABASE_NAME --quick --max_allowed_packet=512M --compress > "$CONFIG/dumps/remote-database-$CURRENT_TIME.sql"

	# echo Remote database exported: remote-database-$CURRENT_TIME.sql

	# Download database dump one table at a time
	for t in $(mysql -NBA -h $REMOTE_DATABASE_HOST -u $REMOTE_DATABASE_USER -p$REMOTE_DATABASE_PASS -D $REMOTE_DATABASE_NAME -e 'show tables') 
	do 
		# Clear any white space
		t=`echo $t`
		if [[ "$IGNORE_TABLES" == *"$t"* ]]; then
			# Ignore tables defined in the ENV file
			echo "SKIPPING TABLE: \"$t\""
		else
		 	echo "DUMPING TABLE: \"$t\""
			if [[ $t == *_options && $IGNORE_ACTIVE_PLUGINS == true ]]; then
			 	# Ignore "active_plugins" option so as not to affect the active plugins
				mysqldump -v -h $REMOTE_DATABASE_HOST -u $REMOTE_DATABASE_USER -p$REMOTE_DATABASE_PASS $REMOTE_DATABASE_NAME $t --where="option_name!='active_plugins'" --skip-comments --no-tablespaces --quick --max_allowed_packet=512M >> "$CONFIG/dumps/remote-database-$CURRENT_TIME.sql"
			else
		 	 	mysqldump -v -h $REMOTE_DATABASE_HOST -u $REMOTE_DATABASE_USER -p$REMOTE_DATABASE_PASS $REMOTE_DATABASE_NAME $t --skip-comments --no-tablespaces --quick --max_allowed_packet=512M >> "$CONFIG/dumps/remote-database-$CURRENT_TIME.sql"
			fi
		 	tbl_count=$(( tbl_count + 1 ))
		fi
	done

	echo "$tbl_count tables dumped from database '$REMOTE_DATABASE_NAME'"
	echo Export file: "remote-database-$CURRENT_TIME.sql"	

	# Upload dump to local database
	echo Importing database \'remote-database-$CURRENT_TIME.sql\' to local server: $LOCAL_DATABASE_HOST
	mysql -h $LOCAL_DATABASE_HOST -u $LOCAL_DATABASE_USER -p$LOCAL_DATABASE_PASS $LOCAL_DATABASE_NAME --max_allowed_packet=512M < "$CONFIG/dumps/remote-database-$CURRENT_TIME.sql"

	echo COMPLETE: Database update complete: $LOCAL_DATABASE_NAME

else
	echo ERROR: Could not connect to the local or remote database
	read -p "Press enter to continue"
fi
