#!/bin/zsh
# record_flow.sh <udid> <label> <evidence-subdir> <seconds> <light|dark> [launch args...]
# Records one DEBUG demo on a headless simulator (never Simulator.app) into
# verify/evidence/<date>/<evidence-subdir>/<label>.mp4, with mock auth and
# setup complete unless CMUX_MOBILE_CLEAR_AUTH / CMUX_MOBILE_SETUP=0 say otherwise. Copies the
# demo timeline (terminal-demo-timeline.txt) and writes <label>.recstart.txt
# (recorder start; the video's t=0 is about 2 s later, as in record_demo.sh).
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
U=$1; L=$2; SUB=$3; T=$4; MODE=$5; shift 5
ROOT=${0:a:h:h:h}
E=$ROOT/verify/evidence/$(date +%Y-%m-%d)/$SUB
APP=$ROOT/build/dd/Build/Products/Debug-iphonesimulator/CmuxMobileApp.app
mkdir -p $E
xcrun simctl terminate $U dev.cmux.mobile >/dev/null 2>&1 || true
xcrun simctl install $U $APP
xcrun simctl spawn $U defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool ${CMUX_MOBILE_SETUP:-true}
xcrun simctl ui $U appearance $MODE
xcrun simctl status_bar $U override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
D=$(xcrun simctl get_app_container $U dev.cmux.mobile data)
rm -f $D/Documents/terminal-demo-timeline.txt
export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1
[[ -n $CMUX_MOBILE_CLEAR_AUTH ]] && export SIMCTL_CHILD_CMUX_MOBILE_CLEAR_AUTH=$CMUX_MOBILE_CLEAR_AUTH
LOG=$E/$L.rec.log
xcrun simctl io $U recordVideo --codec=h264 --force $E/$L.mp4 > $LOG 2>&1 &
RP=$!
until grep -q "Recording started" $LOG; do sleep 0.1; done
# analyze_keyboard.sh assumes video t=0 = recstart + 2 s.
echo $(( $(date +%s.%N) - 2 )) > $E/$L.recstart.txt
xcrun simctl launch $U dev.cmux.mobile "$@" >/dev/null
sleep $T
kill -INT $RP; wait $RP || true
cp $D/Documents/terminal-demo-timeline.txt $E/$L.timeline.txt 2>/dev/null || true
echo "$E/$L.mp4"
