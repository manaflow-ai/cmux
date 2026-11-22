#!/bin/bash
# Ensures the paired iOS 27.0 iPhone 17 Pro Max simulators exist, booted, with
# the software keyboard on; prints "REF=<udid> OURS=<udid>" to ~/imsgreply/udids.
# usage: sims.sh [light|dark]
set -e
export PATH=/opt/homebrew/bin:$PATH
R=com.apple.CoreSimulator.SimRuntime.iOS-27-0
get() { xcrun simctl list devices | grep " $1 (" | head -1 | grep -oE '[0-9A-F-]{36}' || true; }
for n in imsgreply-ref27 imsgreply-ours27; do
  u=$(get $n); [ -z "$u" ] && u=$(xcrun simctl create $n "${DEVICE:-iPhone 17 Pro Max}" $R)
  xcrun simctl boot $u 2>/dev/null || true; xcrun simctl bootstatus $u -b >/dev/null
  for k in AutomaticMinimizationEnabled HardwareKeyboardLastSeen; do xcrun simctl spawn $u defaults write com.apple.keyboard.preferences $k -bool false; done
  # Exact typed text: no autocorrect, predictions or smart punctuation.
  for k in KeyboardAutocorrection KeyboardPrediction KeyboardInlinePrediction KeyboardCheckSpelling SmartQuotesEnabled; do xcrun simctl spawn $u defaults write com.apple.keyboard.preferences $k -bool false; done
  for k in DidShowContinuousPathIntroduction DidShowGestureKeyboardIntroduction; do xcrun simctl spawn $u defaults write com.apple.keyboard.preferences $k -bool true; done
  xcrun simctl shutdown $u; xcrun simctl boot $u; xcrun simctl bootstatus $u -b >/dev/null
  xcrun simctl status_bar $u override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
  xcrun simctl ui $u appearance ${1:-light}
done
echo "REF=$(get imsgreply-ref27) OURS=$(get imsgreply-ours27)" > ~/imsgreply/udids
cat ~/imsgreply/udids
