#!/bin/bash
# Relaunches Messages with ReplyOn and seeds its simulated chats through the
# REF gesture server: texts sent in the first conversation arrive as incoming
# in the second; then two outgoing there. Leaves the second open, keyboard down.
set -e
OUT=${OUT:-/tmp/imsgreply-seed}; source ~/imsgreply/pair.sh
U=$REF
xcrun simctl terminate $U com.apple.MobileSMS 2>/dev/null || true
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$HOME/imsgreply/ReplyOn.dylib xcrun simctl launch $U com.apple.MobileSMS >/dev/null
$A tap --label Messages --element-type Heading --wait-timeout 10 --udid $U >/dev/null 2>&1 || true
row() { g ref tap 220 $1; $A tap --label Message --element-type TextField --wait-timeout 6 --udid $U >/dev/null; sleep 0.6; }
send() { g ref keys "$1"; $A tap --label Send --wait-timeout 4 --udid $U >/dev/null; sleep 0.8; }
row 210
send "Are we still on for dinner tonight"
send "I was thinking the Thai place on Main Street since they have that patio now and it should be really nice out tonight"
send "Let me know by five"
$A tap --label Back --element-type Button --udid $U >/dev/null; sleep 1.2
row 245
send "Yes Thai sounds perfect"
send "Booking for seven"
g ref drag 220 400 220 900 0.02 1500 0; sleep 0.8
