#!/bin/zsh
# record.sh <appearance> <out.mp4> [seconds]
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
UDID=$(cat /tmp/cmux-mobile-ob-review2-udid); APPEAR=$1; OUT=$2; SECS=${3:-7}
BID=dev.cmux.mobile.prod
xcrun simctl terminate $UDID $BID 2>/dev/null
xcrun simctl ui $UDID appearance $APPEAR
# bounded wait for load < 40 (max 10 min)
for i in {1..120}; do L=$(sysctl -n vm.loadavg | awk '{print $2}'); (( L < 40 )) && break; sleep 5; done
echo "load1=$L"
rm -f $OUT
xcrun simctl io $UDID recordVideo --codec=h264 --force $OUT > /tmp/cmux-mobile-ob-review2/rec.log 2>&1 &
RP=$!
for i in {1..100}; do grep -q "Recording started" /tmp/cmux-mobile-ob-review2/rec.log 2>/dev/null && break; kill -0 $RP 2>/dev/null || { echo REC_FAILED; exit 1; }; sleep 0.1; done
sleep 0.5
T0=$(python3 -c 'import time;print(time.time())')
xcrun simctl launch $UDID $BID >/dev/null
T1=$(python3 -c 'import time;print(time.time())')
echo "launch_cmd_start=$T0 returned=$T1"
sleep $SECS
kill -INT $RP; wait $RP
ls -la $OUT
