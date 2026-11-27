#!/bin/bash
cd ~/imsgreply && DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=26.0 -dynamiclib -fobjc-arc -framework UIKit -framework Foundation -framework CoreGraphics ReplyOn.m -o ReplyOn.dylib 2>&1 | grep -E "error|Undefined" ; codesign -f -s - ReplyOn.dylib 2>/dev/null; true
