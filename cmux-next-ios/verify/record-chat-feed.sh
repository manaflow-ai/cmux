#!/usr/bin/env bash
# Builds CmuxMobileApp, runs the DEBUG chat+Feed demo driver on a headless simulator,
# records it, and splits frames. Usage: verify/record-chat-feed.sh <sim-udid> <label> [seconds]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UDID=$1; LABEL=$2; SECONDS_TO_RECORD=${3:-100}
OUT="$ROOT/verify/evidence/$(date +%Y-%m-%d)/chat/$LABEL"
mkdir -p "$OUT/frames"
cd "$ROOT"
xcodegen generate -q
xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -destination "id=$UDID" -derivedDataPath build/dd build -quiet
APP=$(find build/dd/Build/Products -maxdepth 2 -name CmuxMobileApp.app | head -1)
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance dark
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" dev.cmux.mobile >/dev/null 2>&1 || true
rm -f "$OUT/demo.mp4"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT/demo.mp4" &
REC=$!
# Give the recorder its first frame before launching.
until ls "$OUT"/demo.mp4.sb-* >/dev/null 2>&1; do sleep 0.2; done; sleep 1
xcrun simctl launch "$UDID" dev.cmux.mobile -CmuxMobileDemo chat-feed >/dev/null
sleep "$SECONDS_TO_RECORD"
kill -INT $REC; wait $REC || true
ffmpeg -loglevel error -y -i "$OUT/demo.mp4" -vf fps=2,scale=402:-1 "$OUT/frames/f%04d.png"
ffmpeg -loglevel error -y -i "$OUT/demo.mp4" -vf fps=30,scale=402:-1 -frames:v 1 "$OUT/first.png"
echo "$OUT"
