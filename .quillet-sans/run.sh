#!/bin/bash
# Runs a script under src/ with fonttools+brotli on PYTHONPATH (no pip on the Linux pool).
set -e
cd "$(dirname "$0")"
D=/tmp/quillet-sans-deps
[ -d $D/fontTools ] || python3 src/deps.py $D
PYTHONPATH=$D python3 -I -c 'import sys; sys.path.insert(0, "/tmp/quillet-sans-deps"); import fontTools, brotli; print("fonttools", fontTools.version)'
PYTHONPATH=$D python3 "$@"
