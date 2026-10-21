#!/bin/zsh
# record_demo.sh <udid> <label> <phases> <seconds> [extra launch args...]
# Installs the built app on a headless simulator, records the screen while the
# DEBUG demo driver (-CmuxMobileTerminalDemo) runs the given phases, and copies the
# demo timeline and present log next to the video in
# verify/evidence/<date>/terminal/. Build first (see verify/terminal.md).
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
U=$1; L=$2; P=$3; T=$4; shift 4
ROOT=${0:a:h:h:h}
E=$ROOT/verify/evidence/$(date +%Y-%m-%d)/terminal
APP=$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
mkdir -p $E
xcrun simctl terminate $U dev.cmux.mobile >/dev/null 2>&1 || true
xcrun simctl install $U $APP
D=$(xcrun simctl get_app_container $U dev.cmux.mobile data)
rm -f $D/Documents/terminal-demo-timeline.txt $D/Documents/present-log.txt
xcrun simctl io $U recordVideo --codec=h264 --force $E/$L.mp4 > $E/$L.rec.log 2>&1 &
RP=$!
# recordVideo needs a moment to start; recstart + 2 s approximates video t=0.
sleep 2
date +%s.%N > $E/$L.recstart.txt
xcrun simctl launch $U dev.cmux.mobile -CmuxMobileTerminalDemo -CmuxMobileTerminalDemoPhases $P -CmuxMobilePresentLog "$@"
sleep $T
kill -INT $RP; wait $RP || true
cp $D/Documents/terminal-demo-timeline.txt $E/$L.timeline.txt
cp $D/Documents/present-log.txt $E/$L.present.txt 2>/dev/null || true
echo "$E/$L.mp4"
