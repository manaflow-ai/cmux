#!/bin/zsh
# jank.sh UDID LABEL [launch args...]: stream in the demo terminal, fling 8 times, export frame log.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U=$1; L=$2; shift 2
OUT=/tmp/termqa-r5/$L; mkdir -p $OUT
xcrun simctl terminate $U dev.cmux.mobile >/dev/null 2>&1
D=$(xcrun simctl get_app_container $U dev.cmux.mobile data); rm -f $D/Documents/frame-log.ndjson
T0=$(date +%s)
xcrun simctl launch $U dev.cmux.mobile -CmuxMobileTerminalDemo -CmuxMobileTerminalDemoPhases none -CmuxMobileFrameLog "$@" >/dev/null
sleep 4   # stimulus pacing: the demo terminal opens
axe tap --udid $U -x 200 -y 808 >/dev/null; sleep 1
axe type 'stream 6000 8' --udid $U >/dev/null; sleep 1.5
axe tap --udid $U -x 370 -y 808 >/dev/null; sleep 1; axe tap --udid $U -x 370 -y 808 >/dev/null; sleep 3
for i in 1 2 3 4 5 6 7 8; do
  if (( i % 2 )); then axe swipe --udid $U --start-x 200 --start-y 250 --end-x 200 --end-y 650 --duration 0.12 >/dev/null
  else axe swipe --udid $U --start-x 200 --start-y 600 --end-x 200 --end-y 300 --duration 0.15 >/dev/null; fi
  sleep 1.6
done
sleep 2
xcrun simctl spawn $U log show --start "$(date -r $T0 '+%Y-%m-%d %H:%M:%S')" --predicate 'subsystem == "dev.cmux.mobile" AND (category == "frames" OR eventMessage CONTAINS "pin:" OR eventMessage CONTAINS "scroll pacing" OR eventMessage CONTAINS "jump to bottom")' --style compact > $OUT/log.txt 2>/dev/null
xcrun simctl terminate $U dev.cmux.mobile >/dev/null 2>&1; sleep 1
cp $D/Documents/frame-log.ndjson $OUT/ 2>/dev/null
echo $OUT; wc -l $OUT/frame-log.ndjson
