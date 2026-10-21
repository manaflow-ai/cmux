#!/usr/bin/env bash
# Live end-to-end recording against a real Mac (see verify/live.md).
# usage: CMUX_MOBILE_STACK_EMAIL=... CMUX_MOBILE_STACK_PASSWORD=... verify/record-live.sh <udid> <out-dir> [seconds] [demo] [transport]
# transport is wireguard (default) or webrtc. verify/connectivity.md uses demo
# relay-only to switch Settings → Developer → Relay only on mid-run.
# Credentials come from the environment only and are passed to the app as
# SIMCTL_CHILD_* variables; nothing is printed.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1; out=$2; seconds=${3:-150}; demo=${4:-live}; transport=${5:-wireguard}
: "${CMUX_MOBILE_STACK_EMAIL:?}" "${CMUX_MOBILE_STACK_PASSWORD:?}"
mkdir -p "$out"
cd "$(dirname "$0")/.."
xcrun simctl terminate "$udid" dev.cmux.mobile 2>/dev/null || true
xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/live.mp4" &
rec=$!
trap 'kill -INT $rec 2>/dev/null || true' EXIT
SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$CMUX_MOBILE_STACK_EMAIL" SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$CMUX_MOBILE_STACK_PASSWORD" \
  xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-tab workspaces -cmuxMobile.setupComplete 1 \
  -cmuxMobile.settings.transport "$transport" -cmux-mobile-demo "$demo" > /dev/null
xcrun simctl spawn "$udid" log stream --level info --predicate 'subsystem == "dev.cmux.mobile"' --style compact > "$out/app.log" 2>&1 &
logpid=$!
# Wall-clock stills alongside the video (the video drops static stretches).
mkdir -p "$out/stills"
( while kill -0 $rec 2>/dev/null; do xcrun simctl io "$udid" screenshot "$out/stills/$(date +%H%M%S).png" >/dev/null 2>&1; done ) &
# Recording length: the demo's own pacing; the clip stops after `seconds`.
perl -e "select(undef,undef,undef,$seconds)"
kill -INT $rec; wait $rec 2>/dev/null || true
kill $logpid 2>/dev/null || true
trap - EXIT
mkdir -p "$out/frames"
ffmpeg -loglevel error -y -i "$out/live.mp4" -vf fps=1 "$out/frames/f%04d.png"
echo "frames: $(ls "$out/frames" | wc -l | tr -d ' ')"
