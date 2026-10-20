#!/usr/bin/env bash
# Phone side of verify/browser-stream.md: launch the Debug app signed in with
# the DEBUG dev credential (CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD from the
# environment, passed as SIMCTL_CHILD_*; never printed), record the screen,
# stream the app log and take a wall-clock still every ~0.3 s.
# usage: verify/record-browser.sh <udid> <out-dir> start [transport [extra launch args]] | stop
# Extra args such as `-cmuxMobile.live.mac.<team> <mac device id>` pick the Mac.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1; out=$2; mode=$3; transport=${4:-wireguard}; shift $(( $# < 4 ? $# : 4 ))
mkdir -p "$out/stills"
case $mode in
start)
  : "${CMUX_MOBILE_STACK_EMAIL:?}" "${CMUX_MOBILE_STACK_PASSWORD:?}"
  xcrun simctl terminate "$udid" dev.cmux.mobile 2>/dev/null || true
  SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$CMUX_MOBILE_STACK_EMAIL" SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$CMUX_MOBILE_STACK_PASSWORD" \
    xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-tab workspaces -cmuxMobile.setupComplete 1 \
    -cmuxMobile.settings.transport "$transport" "$@" > /dev/null
  nohup xcrun simctl spawn "$udid" log stream --level info --predicate 'subsystem == "dev.cmux.mobile"' --style compact > "$out/app.log" 2>&1 &
  echo $! > "$out/log.pid"
  nohup xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/browser.mp4" > "$out/rec.log" 2>&1 &
  echo $! > "$out/rec.pid"
  ( while [[ -f "$out/rec.pid" ]]; do xcrun simctl io "$udid" screenshot "$out/stills/$(python3 -c 'import time;print(int(time.time()*1000))').png" >/dev/null 2>&1; done ) &
  echo started
  ;;
stop)
  kill -INT "$(cat "$out/rec.pid")" 2>/dev/null || true
  rm -f "$out/rec.pid"
  kill "$(cat "$out/log.pid")" 2>/dev/null || true
  echo "stills: $(ls "$out/stills" | wc -l | tr -d ' ')"
  ;;
esac
