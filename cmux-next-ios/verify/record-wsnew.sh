#!/usr/bin/env bash
# Records the new-workspace demo (`-cmux-mobile-demo workspace-new`: tap, hold,
# pick, refusal) on one headless simulator, streams the demo log, and
# splits frames. Needs a built app (verify/build.sh).
# usage: verify/record-wsnew.sh <udid> <label> [light|dark] [fps]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 mode=${3:-dark} fps=${4:-4}
out="verify/evidence/$(date +%Y-%m-%d)/wsnew/$label"
mkdir -p "$out"
app=build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
xcrun simctl install "$udid" "$app"
xcrun simctl spawn "$udid" defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool true
xcrun simctl ui "$udid" appearance "$mode"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
video="$out/workspace-new-$mode.mp4" reclog=$(mktemp)
xcrun simctl spawn "$udid" log stream --level info --predicate 'subsystem == "dev.cmux.mobile"' >"$out/app.log" 2>&1 &
logger=$!
xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >"$reclog" 2>&1 &
rec=$!
until grep -q "Recording started" "$reclog"; do sleep 0.1; done
xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-demo workspace-new >/dev/null
sleep 30
kill -INT "$rec"; wait "$rec" || true
kill "$logger" || true
rm -rf "$out/frames"; mkdir -p "$out/frames"
ffmpeg -loglevel error -y -i "$video" -vf "fps=$fps,scale=402:-1" "$out/frames/f%04d.png"
echo "$video"
