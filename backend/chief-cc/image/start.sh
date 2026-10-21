#!/usr/bin/env bash
# Starts one turn (run.mjs) detached and returns at once (chief-brain-cc/vm.ts; exec stdin = the
# turn's JSON input, which holds the per-turn token: root-only file, run.mjs deletes it at start).
set -euo pipefail
run="${1:?run}"
[[ "$run" =~ ^run_[0-9]{1,15}$ ]] || exit 2
umask 077
install -d -m 700 /run/chief
rm -f "/run/chief/$run.out"
cat > "/run/chief/$run.in"
setsid nohup /opt/node/bin/node /opt/chief-cc/run.mjs "$run" > "/run/chief/$run.log" 2>&1 < /dev/null &
echo started
