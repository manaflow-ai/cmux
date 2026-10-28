#!/bin/zsh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U=$1; OUT=/tmp/termqa-r5/jump; mkdir -p $OUT
xcrun simctl terminate $U dev.cmux.mobile >/dev/null 2>&1
T0=$(date +%s)
xcrun simctl launch $U dev.cmux.mobile -CmuxMobileTerminalDemo -CmuxMobileTerminalDemoPhases none -CmuxMobileFrameLog >/dev/null
sleep 4
axe tap --udid $U -x 200 -y 808 >/dev/null; sleep 1
axe type 'stream 9000 8' --udid $U >/dev/null; sleep 1.5
axe tap --udid $U -x 370 -y 808 >/dev/null; sleep 1; axe tap --udid $U -x 370 -y 808 >/dev/null; sleep 4
axe swipe --udid $U --start-x 200 --start-y 250 --end-x 200 --end-y 650 --duration 0.12 >/dev/null; sleep 1.5
B=$(axe describe-ui --udid $U | python3 -c "
import json,sys
d=json.load(sys.stdin)
def walk(n):
    if n.get('AXLabel')=='Scroll to bottom':
        f=n['frame']; print(f\"{f['x']+f['width']/2:.0f} {f['y']+f['height']/2:.0f}\"); sys.exit()
    for c in n.get('children',[]): walk(c)
for n in (d if isinstance(d,list) else [d]): walk(n)
")
echo "button at $B"
axe tap --udid $U -x ${B% *} -y ${B#* } >/dev/null; sleep 2
for delay in 0.1 0.3 0.6; do
  axe swipe --udid $U --start-x 200 --start-y 250 --end-x 200 --end-y 700 --duration 0.1 >/dev/null &
  SW=$!
  sleep $((0.1 + delay)); axe tap --udid $U -x ${B% *} -y ${B#* } >/dev/null; wait $SW
  sleep 1.2; xcrun simctl io $U screenshot $OUT/after-$delay.png >/dev/null 2>&1; sleep 1.5
done
xcrun simctl spawn $U log show --start "$(date -r $T0 '+%Y-%m-%d %H:%M:%S')" --predicate 'subsystem == "dev.cmux.mobile" AND (eventMessage CONTAINS "jump to bottom" OR eventMessage CONTAINS "settled" OR eventMessage CONTAINS "fling reached")' --style compact > $OUT/log.txt 2>/dev/null
cut -c1-24,60-260 $OUT/log.txt | grep -v Timestamp
