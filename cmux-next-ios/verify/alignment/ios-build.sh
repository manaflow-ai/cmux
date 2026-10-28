#!/bin/zsh -l
# Builds the cmux-next iOS app (Demo, simulator arm64) on a cmux mini from a source
# tree shipped there with `git archive` (see README in measure.py's docstring).
#   ios-build.sh DIR      DIR/src is the archive; DIR/dd the derived data; logs in DIR/logs
# CmuxMobileLinkFFI.xcframework comes from ~/cmux-mobile-builds/.cache/xcframework/<key>
# (the demo-build.sh key, passed as XCF_KEY), else it is built (JOBS=4) and cached.
set -uo pipefail
export PATH=$HOME/r13-tools/xcodegen/bin:$HOME/r13-tools/axe:/opt/homebrew/bin:$HOME/.cargo/bin:$PATH
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}
D=${1:?usage: ios-build.sh DIR}; S=$D/src/cmux-next-ios; L=$D/logs; mkdir -p $L
xcf=$S/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework
cache=$HOME/cmux-mobile-builds/.cache/xcframework/${XCF_KEY:-none}/CmuxMobileLinkFFI.xcframework
if [[ -d $cache ]]; then rm -rf $xcf; mkdir -p ${xcf:h}; cp -R $cache $xcf; echo "xcf: cache hit ${XCF_KEY}"
else (cd $S/rust && JOBS=4 bash scripts/build-xcframework.sh > $L/xcframework.log 2>&1); echo "xcf build rc=$?"
     [[ -n ${XCF_KEY:-} ]] && { mkdir -p ${cache:h}; cp -R $xcf ${cache:h}/; }
fi
cd $S && xcodegen generate -q > $L/xcodegen.log 2>&1; echo "xcodegen rc=$?"
nice -n 10 xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath $D/dd -clonedSourcePackagesDirPath $HOME/cmux-mobile-builds/.cache/spm -jobs 4 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' build > $L/ios-sim.log 2>&1; echo "sim rc=$?"
grep -E 'error:|BUILD (FAILED|SUCCEEDED)' $L/ios-sim.log | sort -u | head -20
ls -d $D/dd/Build/Products/Demo-iphonesimulator/*.app
