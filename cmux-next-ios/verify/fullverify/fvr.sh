#!/usr/bin/env bash
# Laptop-side shim: run fv.py commands on the rig mini. usage: fvr.sh CMD ARGS... ; fvr.sh sh 'shell on mini'
# FV_ENV (JSON) is passed to `fv.py launch` as the app's launch environment.
host=${FV_HOST:-mini-cmuxs-mac-mini-2}
dir=${FV_DIR:-cmux-mobile-fixr1}
if [[ "$1" == sh ]]; then shift; exec ssh -o BatchMode=yes "$host" "cd ~/$dir && export PATH=\$HOME/$dir/bin:/opt/homebrew/bin:\$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; $*"; fi
q=$(printf '%q ' "$@")
fe=$(printf '%q' "${FV_ENV:-"{}"}")
exec ssh -o BatchMode=yes "$host" "cd ~/$dir && FV_ENV=$fe python3 fv.py $q"
