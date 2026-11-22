#!/bin/bash
# Every reply scenario, Messages (REF) beside Chief (OURS), on the paired
# iOS 27 simulators. Stills -> $OUT/NN-name-{ref,ours,sbs}; motion -> mp4s.
# usage: OUT=<dir> bash scenarios.sh [scenario ...]   (default: all)
OUT=${OUT:-$HOME/imsgreply/out/light}; source ~/imsgreply/pair.sh
# Bubble centers (points) after a reset. Messages' simulated chat gives every
# incoming message its own tail (the stub breaks the run), so its rows sit lower.
ROOT_R=252; ROOT_O=252      # "Are we still on…" (incoming, short)
LONG_R=333; LONG_O=318      # long incoming
FIVE_R=407; FIVE_O=401      # "Let me know by 5"
OUT1_R=457; OUT1_O=452      # "Yes! Thai sounds perfect" (outgoing)
OUT2_R=501; OUT2_O=496      # "Booking for 7"
fresh() { bash ~/imsgreply/oursseed.sh >/dev/null 2>&1; bash ~/imsgreply/refseed.sh >/dev/null 2>&1; sleep 1; kbdown_both; sleep 0.5; }
closeReply() { gb tap 398 84; sleep 1.0; kbdown_both; sleep 0.5; }
tapsend() { $A tap --label "Send Reply" --udid $1 >/dev/null 2>&1 || $A tap --label Send --udid $1 >/dev/null 2>&1; }
# Waits only on its own taps: a bare `wait` would also wait on the recorders.
sendboth() { tapsend $REF & local a=$!; tapsend $OURS & local b=$!; wait $a $b; }
send() { gb keys "$1"; sleep 0.3; sendboth; sleep 1.6; }
kbdown() { kbdown_both; sleep 0.5; }
run() {
  case $1 in
  menu-incoming)   # long-press > Reply on an incoming message, its thread, cancel
    fresh; shot 00-transcript
    rec_start 01-menu-reply-incoming
    press_text "Are we still on for dinner"; sleep 1.1; shot 01-menu-incoming
    ref tap --label Reply; ours tap --label Reply; sleep 1.4
    rec_stop; shot 02-reply-mode-incoming
    rec_start 03-reply-cancel; closeReply; rec_stop; shot 03-after-cancel ;;
  swipe-incoming)  # swipe right on the long incoming message, held mid-swipe and committed
    fresh
    SWIPE_V=300 swipe_text "I was thinking the Thai place" 75 1.2 & held=$!
    sleep 1.25; shot 04-swipe-held-incoming; wait $held
    closeReply
    rec_start 05-swipe-reply-incoming
    swipe_text "I was thinking the Thai place" 130; sleep 1.5
    rec_stop; shot 05-reply-mode-swipe-long ;;
  swipe-outgoing)  # swipe right on my own message
    fresh
    SWIPE_V=300 swipe_text "Yes Thai sounds perfect" 80 1.2 & held=$!
    sleep 1.25; shot 06-swipe-held-outgoing; wait $held
    closeReply
    rec_start 07-swipe-reply-outgoing
    swipe_text "Yes Thai sounds perfect" 130; sleep 1.5
    rec_stop; shot 07-reply-mode-outgoing ;;
  send-incoming)   # reply to an incoming message: draft, send, the quote and thread line in the transcript
    fresh
    swipe_text "Let me know by five" 130; sleep 1.5
    gb keys "Sounds good see you there"; sleep 0.6; shot 08-reply-draft
    rec_start 09-reply-send; sendboth; sleep 2.2; rec_stop
    shot 09-after-send-thread; closeReply; shot 10-transcript-reply-incoming ;;
  send-outgoing)   # reply to my own message
    fresh
    swipe_text "Booking for seven" 130; sleep 1.5
    send "Actually make it half past"; shot 11a-after-send-outgoing; closeReply; shot 11-transcript-reply-outgoing ;;
  thread)          # second reply in the same thread, "N Replies", open the thread from the quote
    fresh
    swipe_text "Let me know by five" 130; sleep 1.5
    send "Sounds good"; shot 12-thread-one-reply
    send "Want me to grab a table outside"; shot 12b-thread-two-replies
    closeReply; shot 13-transcript-two-replies
    rec_start 14-open-thread-from-quote
    for u in $REF $OURS; do q=$(center_of $u "1 Reply"); [ -n "$q" ] && $A tap -x ${q% *} -y ${q#* } --udid $u >/dev/null 2>&1; done
    sleep 1.5; rec_stop; shot 14-thread-from-replies ;;
  long)            # reply to the long message: quote clipping
    fresh
    swipe_text "I was thinking the Thai place" 130; sleep 1.5
    send "Patio for sure"; closeReply; shot 15-transcript-reply-long ;;
  tapback)         # heart on a reply bubble
    fresh
    swipe_text "Let me know by five" 130; sleep 1.5
    send "Sounds good"; closeReply; shot 16a-transcript
    press_text "Sounds good"; sleep 1.1; shot 16-reply-menu
    # The heart is the bar's first tapback on both sides.
    for u in $REF $OURS; do h=$(center_of $u "Heart"); [ -z "$h" ] && h=$(center_of $u "Love"); [ -n "$h" ] && $A tap -x ${h% *} -y ${h#* } --udid $u >/dev/null 2>&1; done
    sleep 1.2; shot 17-reply-tapback ;;
  esac
}
for s in ${@:-menu-incoming swipe-incoming swipe-outgoing send-incoming send-outgoing thread long tapback}; do echo "== $s"; run $s; done
