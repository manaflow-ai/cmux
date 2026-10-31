#!/usr/bin/env bash
# Records `-cmux-mobile-demo chief-parity` on one headless simulator (Home without a
# title, New Message to an agent and to Chief, the send-time drawer, a photo
# send, the Photos drawer) and splits frames: 2 fps for the whole run and
# 15 fps for the drawer windows. Needs a built app (verify/build.sh).
# usage: verify/record-chief-parity.sh <udid> <label> [light|dark]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 mode=${3:-dark}
out="verify/evidence/$(date +%Y-%m-%d)/chief/$label"
mkdir -p "$out"
app=build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
xcrun simctl install "$udid" "$app"
xcrun simctl terminate "$udid" com.apple.MobileSMS >/dev/null 2>&1 || true
xcrun simctl spawn "$udid" defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool true
# The Photos drawer reads the library: grant it and give it a few photos.
xcrun simctl privacy "$udid" grant photos dev.cmux.mobile
xcrun simctl ui "$udid" appearance "$mode"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1

video="$out/chief-parity-$mode.mp4"
log=$(mktemp)
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
docs=$(xcrun simctl get_app_container "$udid" dev.cmux.mobile data)/Documents
rm -f "$docs/terminal-demo-timeline.txt"
xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >"$log" 2>&1 &
rec=$!
until grep -q "Recording started" "$log"; do sleep 0.1; done
start=$(python3 -c 'import time; print(time.time())')
xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-demo chief-parity >/dev/null
# Pacing for the recording only: the demo's last mark is "end".
until grep -q " end$" "$docs/terminal-demo-timeline.txt" 2>/dev/null; do sleep 0.5; done
kill -INT "$rec"; wait "$rec" || true
crash=$(xcrun simctl spawn "$udid" launchctl list | grep -c "UIKitApplication:dev.cmux.mobile" || true)
echo "app still running after demo: $crash"
awk -v s="$start" '{ printf "%.2f %s\n", $1 - s, substr($0, index($0, " ") + 1) }' "$docs/terminal-demo-timeline.txt" > "$out/timeline.txt"
mkdir -p "$out/frames"
ffmpeg -loglevel error -y -i "$video" -vf fps=2,scale=402:-1 "$out/frames/f%04d.png"
while read -r t name; do
  case $name in timestamps*) ;; *) continue ;; esac
  dir="$out/drawer-${name// /-}"
  mkdir -p "$dir"
  ffmpeg -loglevel error -y -ss "$t" -t 3.2 -i "$video" -vf fps=15,scale=402:-1 "$dir/f%03d.png"
done < "$out/timeline.txt"
echo "$video"
