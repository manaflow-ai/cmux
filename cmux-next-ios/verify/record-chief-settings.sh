#!/usr/bin/env bash
# Records `-cmux-mobile-demo chief-settings` on one headless simulator: Chief, its
# settings opened from the header (in place of the package's contact
# details), and Hide Alerts / Send Read Receipts flipping on and off. Splits
# 30 fps frames around each flip so the switch animation can be checked frame
# by frame. Needs a built app (verify/build.sh).
# usage: verify/record-chief-settings.sh <udid> <label> [light|dark]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 mode=${3:-dark}
out="verify/evidence/$(date +%Y-%m-%d)/chief-settings/$label"
mkdir -p "$out"
app=build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
xcrun simctl install "$udid" "$app"
xcrun simctl spawn "$udid" defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool true
xcrun simctl ui "$udid" appearance "$mode"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1
video="$out/chief-settings-$mode.mp4"
log=$(mktemp)
xcrun simctl terminate "$udid" dev.cmux.mobile >/dev/null 2>&1 || true
docs=$(xcrun simctl get_app_container "$udid" dev.cmux.mobile data)/Documents
rm -f "$docs/terminal-demo-timeline.txt"
xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >"$log" 2>&1 &
rec=$!
until grep -q "Recording started" "$log"; do sleep 0.1; done
start=$(python3 -c 'import time; print(time.time())')
xcrun simctl launch "$udid" dev.cmux.mobile -cmux-mobile-demo chief-settings >/dev/null
until grep -q " end$" "$docs/terminal-demo-timeline.txt" 2>/dev/null; do sleep 0.5; done
kill -INT "$rec"; wait "$rec" || true
awk -v s="$start" '{ printf "%.2f %s\n", $1 - s, substr($0, index($0, " ") + 1) }' "$docs/terminal-demo-timeline.txt" > "$out/timeline.txt"
mkdir -p "$out/frames"
ffmpeg -loglevel error -y -i "$video" -vf fps=2,scale=402:-1 "$out/frames/f%04d.png"
while read -r t name; do
  case $name in hide*|receipts*) ;; *) continue ;; esac
  dir="$out/flip-${name// /-}"
  mkdir -p "$dir"
  ffmpeg -loglevel error -y -ss "$t" -t 0.6 -i "$video" -vf fps=30,scale=402:-1 "$dir/f%03d.png"
done < "$out/timeline.txt"
echo "$video"
