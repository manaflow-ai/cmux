#!/bin/zsh -l
# Builds the cmux-next iOS app (Demo, simulator arm64) from ~/multimac-ios/src on this mini.
set -uo pipefail
export PATH=/opt/homebrew/bin:$HOME/.cargo/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
D=~/multimac-ios; S=$D/src/cmux-next-ios; L=$D/logs; mkdir -p $L
cd $S/rust && JOBS=6 bash scripts/build-xcframework.sh > $L/xcframework.log 2>&1; echo "xcf rc=$?"; tail -2 $L/xcframework.log
cd $S && xcodegen generate -q > $L/xcodegen.log 2>&1; echo "xcodegen rc=$?"
xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath $D/dd -jobs 6 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' build > $L/ios-sim.log 2>&1; echo "sim rc=$?"
grep -E 'error:|BUILD (FAILED|SUCCEEDED)' $L/ios-sim.log | sort -u | head -20
ls -d $D/dd/Build/Products/Demo-iphonesimulator/*.app
