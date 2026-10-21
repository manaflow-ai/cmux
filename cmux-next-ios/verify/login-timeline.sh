#!/usr/bin/env bash
# Screenshot the welcome intro frozen at exact intro times (DEBUG
# -cmux-mobile-intro-freeze), signed out, on one headless simulator.
# usage: verify/login-timeline.sh <udid> <light|dark> <out dir> [times...]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 appearance=$2 out=$3; shift 3
times=("$@")
[ ${#times[@]} -gt 0 ] || times=(0 0.1 0.25 0.5 0.75 1 1.5 2 2.5 3 3.5 4 4.5 5 5.5 6.5)
mkdir -p "$out"
xcrun simctl ui "$udid" appearance "$appearance"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CMUX_MOBILE_CLEAR_AUTH=1
for t in "${times[@]}"; do
  xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-intro-freeze "$t" >/dev/null
  # Auth resolves and the welcome mounts within ~2 s (longer under load); the frame is frozen after.
  sleep 6
  xcrun simctl io "$udid" screenshot "$out/t$t.png" >/dev/null 2>&1
  echo "$out/t$t.png"
done
