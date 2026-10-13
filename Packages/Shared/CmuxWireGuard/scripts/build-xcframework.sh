#!/usr/bin/env bash
# Builds CmuxWG.xcframework (libcmuxwg: wireguard-go on gVisor netstack) from
# go/ for macOS (arm64, x86_64), iOS and the iOS simulator.
#
# Usage: build-xcframework.sh [--if-stale]
#   --if-stale  skip the build when the xcframework is newer than every
#               Go source file and go.sum.
#
# Needs Go (GO=/path/to/go overrides) and Xcode. Output:
#   Packages/Shared/CmuxWireGuard/Frameworks/CmuxWG.xcframework (git-ignored)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/go"
out="$root/Frameworks/CmuxWG.xcframework"
go_bin="${GO:-$(command -v go || true)}"

if [[ "${1:-}" == "--if-stale" && -d "$out" ]]; then
  newest="$(find "$src" -name '*.go' -o -name 'go.sum' -o -name 'go.mod' | xargs stat -f '%m' | sort -n | tail -1)"
  built="$(stat -f '%m' "$out/Info.plist")"
  if (( built >= newest )); then
    echo "CmuxWG.xcframework is current"
    exit 0
  fi
fi

if [[ -z "$go_bin" ]]; then
  echo "build-xcframework: Go is required (set GO=/path/to/go)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

build() { # name goos goarch sdk target
  local name="$1" goos="$2" goarch="$3" sdk="$4" target="$5"
  local sysroot cc
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  mkdir -p "$work/$name"
  (
    cd "$src"
    CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" \
      CC="$cc" CGO_CFLAGS="-isysroot $sysroot -target $target -fembed-bitcode=off" \
      CGO_LDFLAGS="-isysroot $sysroot -target $target" \
      "$go_bin" build -trimpath -buildmode=c-archive -ldflags='-s -w' \
      -o "$work/$name/libcmuxwg.a" .
  )
}

build macos-arm64 darwin arm64 macosx arm64-apple-macos13.0
build macos-x86_64 darwin amd64 macosx x86_64-apple-macos13.0
build ios-arm64 ios arm64 iphoneos arm64-apple-ios17.0
build sim-arm64 ios arm64 iphonesimulator arm64-apple-ios17.0-simulator

mkdir -p "$work/macos"
lipo -create "$work/macos-arm64/libcmuxwg.a" "$work/macos-x86_64/libcmuxwg.a" -output "$work/macos/libcmuxwg.a"

headers="$work/Headers"
# A subdirectory: Xcode copies every static xcframework's Headers into one
# include/ folder, so a top-level module.modulemap collides with other
# libraries' (GhosttyNextKit).
mkdir -p "$headers/CmuxWGC"
cp "$work/macos-arm64/libcmuxwg.h" "$headers/CmuxWGC/libcmuxwg.h"
cat > "$headers/CmuxWGC/module.modulemap" <<'EOF'
module CmuxWGC {
    header "libcmuxwg.h"
    link "resolv"
    export *
}
EOF

rm -rf "$out"
mkdir -p "$(dirname "$out")"
xcodebuild -create-xcframework \
  -library "$work/macos/libcmuxwg.a" -headers "$headers" \
  -library "$work/ios-arm64/libcmuxwg.a" -headers "$headers" \
  -library "$work/sim-arm64/libcmuxwg.a" -headers "$headers" \
  -output "$out" >/dev/null
echo "built $out"
