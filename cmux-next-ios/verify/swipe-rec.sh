#!/usr/bin/env bash
# Record a real HID drag (axe) on a headless simulator and split it into
# 10 fps frames. Start at x=1 for an edge swipe, mid-screen for the iOS 26
# full-width back swipe. Y (env, points) picks the row; avoid horizontal
# scrollers when testing the plain pop.
# usage: verify/swipe-rec.sh <udid> <out-dir> <label> <startx> <endx> [duration]
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
udid=$1 dir=$2 label=$3 sx=$4 ex=$5 dur=${6:-0.8}
mkdir -p "$dir"
log=$(mktemp)
xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/$label.mp4" >"$log" 2>&1 &
rec=$!
until grep -q "Recording started" "$log"; do sleep 0.1; done
sleep 0.5
axe drag --start-x "$sx" --start-y "${Y:-450}" --end-x "$ex" --end-y "${Y:-450}" --duration "$dur" --steps 60 --udid "$udid" >/dev/null
sleep 1.2
kill -INT $rec; wait $rec || true
rm -rf "$dir/$label-frames"; mkdir -p "$dir/$label-frames"
ffmpeg -loglevel error -y -i "$dir/$label.mp4" -vf "fps=10,scale=300:-1" "$dir/$label-frames/f%03d.png"
ls "$dir/$label-frames" | wc -l
