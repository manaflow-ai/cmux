#!/bin/zsh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
U=$1; OUT=/tmp/termqa-r5/pin; mkdir -p $OUT
xcrun simctl terminate $U dev.cmux.mobile >/dev/null 2>&1
T0=$(date +%s)
xcrun simctl launch $U dev.cmux.mobile -CmuxMobileTerminalDemo -CmuxMobileTerminalDemoPhases none -CmuxMobileFrameLog >/dev/null
sleep 4
axe tap --udid $U -x 200 -y 808 >/dev/null; sleep 1.5
xcrun simctl io $U screenshot $OUT/focus-1line.png >/dev/null 2>&1
axe type 'echo three lines of composer text that wrap onto a second and then onto a third line here' --udid $U >/dev/null; sleep 1.5
xcrun simctl io $U screenshot $OUT/focus-3lines.png >/dev/null 2>&1
axe type ' and more words so that the draft keeps growing until it reaches about six lines in the card for the test' --udid $U >/dev/null; sleep 1.5
xcrun simctl io $U screenshot $OUT/focus-6lines.png >/dev/null 2>&1
axe tap --udid $U -x 200 -y 300 >/dev/null; sleep 1.5
xcrun simctl io $U screenshot $OUT/rest-6lines.png >/dev/null 2>&1
xcrun simctl spawn $U log show --start "$(date -r $T0 '+%Y-%m-%d %H:%M:%S')" --predicate 'subsystem == "dev.cmux.mobile" AND eventMessage CONTAINS "pin:"' --style compact > $OUT/log.txt 2>/dev/null
cut -c12-23,100-260 $OUT/log.txt | grep -v Timestamp | awk '{k=$0; sub(/rows [0-9]+\)/,"",k); if (k!=last) print; last=k}'
