#!/usr/bin/env bash
# Record one scripted flow on a headless simulator (no Simulator.app window).
# usage: verify/record.sh <udid> <out.mp4> <seconds> <light|dark> [launch args...]
# Environment passed to the app: any CMUX_MOBILE_* variable exported by the caller
# (e.g. CMUX_MOBILE_MOCK_AUTH=1, CMUX_MOBILE_CLEAR_AUTH=1, CMUX_MOBILE_STACK_EMAIL/PASSWORD) is
# forwarded with the SIMCTL_CHILD_ prefix. Secrets are never echoed.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 out=$2 seconds=$3 appearance=$4; shift 4
xcrun simctl ui "$udid" appearance "$appearance"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
while IFS='=' read -r name _; do
  case "$name" in CMUX_MOBILE_*) export "SIMCTL_CHILD_$name=${!name}" ;; esac
done < <(env)
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
mkdir -p "$(dirname "$out")"
log=$(mktemp)
xcrun simctl io "$udid" recordVideo --codec ${CMUX_MOBILE_RECORD_CODEC:-h264} --force "$out" >"$log" 2>&1 &
rec=$!
# Launch only once the recorder reports it is capturing.
until grep -q "Recording started" "$log"; do sleep 0.1; done
xcrun simctl launch "$udid" dev.cmux.mobile "$@" >/dev/null
sleep "$seconds"
kill -INT "$rec"
wait "$rec" || true
echo "$out"
