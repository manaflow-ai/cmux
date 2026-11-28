#!/bin/sh -e
#
# Valgrind wrapper

# Default Debian debug libraries.
DBGPATH=/usr/lib/debug

# Use debug libraries if found.
if [ -z "$LD_LIBRARY_PATH" ]; then
	export LD_LIBRARY_PATH="$DBGPATH"
else
	export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$DBGPATH"
fi

# Force C++ STL to use malloc and to free memory by disabling 
# memory caching.
# For gcc < 3.4 versions
export GLIBCPP_FORCE_NEW=1

# For gcc >= 3.4 versions
export GLIBCXX_FORCE_NEW=1

# Use 'exec' to avoid having another shell process hanging around.
exec $0.bin "$@"
