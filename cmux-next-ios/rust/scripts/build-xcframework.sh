#!/usr/bin/env bash
# Builds CmuxMobileLinkFFI.xcframework (aarch64-apple-ios, aarch64-apple-ios-sim) and the
# generated Swift bindings for cmux-mobile-link-ffi.
#
# Outputs (paths relative to cmux-next-ios/):
#   CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework   static framework `CmuxMobileLinkFFIFFI` per slice
#   CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift     generated Swift (module CmuxMobileLinkFFI)
#
# Package.swift wiring:
#   .binaryTarget(name: "CmuxMobileLinkFFIFFI", path: "Frameworks/CmuxMobileLinkFFI.xcframework"),
#   .target(name: "CmuxMobileLinkFFI", dependencies: ["CmuxMobileLinkFFIFFI"], path: "Sources/CmuxMobileLinkFFI",
#           linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]),
#
# Environment: JOBS (default 6), IPHONEOS_DEPLOYMENT_TARGET (default 17.0),
# DEVELOPER_DIR (default /Applications/Xcode.app/Contents/Developer; the
# selected command line tools have no iOS SDK). SKIP_VERIFY=1 skips the
# Swift typecheck and simulator link check.
set -euo pipefail

rust_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmux_mobile_dir="$(cd "$rust_dir/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
# Thin LTO would leave LLVM bitcode that Apple's ld may not read.
export CARGO_PROFILE_RELEASE_LTO=off
jobs="${JOBS:-6}"
name=CmuxMobileLinkFFIFFI
lib=libcmux_mobile_link_ffi.a
targets=(aarch64-apple-ios aarch64-apple-ios-sim)

cd "$rust_dir"
installed="$(rustup target list --installed)"
for target in "${targets[@]}"; do
  grep -qx "$target" <<<"$installed" || rustup target add "$target"
done

# webrtc-util depends on nix 0.26, whose Apple system-control socket code
# names libc items (sockaddr_ctl, AF_SYS_CONTROL, SYSPROTO_*) that current libc
# no longer exports for iOS. For the iOS builds only, patch nix with a copy
# that defines them itself (the Darwin values). The checked-in Cargo.lock is
# restored afterwards; host builds and tests use stock nix.
cargo fetch --locked
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
nix_src="$(ls -d "$cargo_home"/registry/src/*/nix-0.26.4 2>/dev/null | head -1)"
[[ -d "$nix_src" ]] || { echo "error: nix-0.26.4 source not found under $cargo_home/registry/src" >&2; exit 1; }
patched="$rust_dir/target/ios-patches/nix-0.26.4"
rm -rf "$patched"
mkdir -p "$(dirname "$patched")"
cp -R "$nix_src" "$patched"
chmod -R u+w "$patched"
sed -i '' -e 's/libc::sockaddr_ctl/crate::darwin_ctl::sockaddr_ctl/g' \
  -e 's/libc::AF_SYS_CONTROL/crate::darwin_ctl::AF_SYS_CONTROL/g' "$patched/src/sys/socket/addr.rs"
sed -i '' -e 's/libc::SYSPROTO_EVENT/crate::darwin_ctl::SYSPROTO_EVENT/g' \
  -e 's/libc::SYSPROTO_CONTROL/crate::darwin_ctl::SYSPROTO_CONTROL/g' "$patched/src/sys/socket/mod.rs"
# A path dependency is linted like workspace code; nix denies `unused`, which
# newer rustc reports on code nix never meant to keep.
sed -i '' -e 's/^#!\[deny(unused)\]/#![allow(warnings)]/' "$patched/src/lib.rs"
cat >> "$patched/src/lib.rs" <<'RUST'

/// cmux-next-ios patch: Darwin's system-control socket items, which libc no
/// longer exports for iOS (`<sys/kern_control.h>`, `<sys/sys_domain.h>`).
#[cfg(any(target_os = "ios", target_os = "macos"))]
#[allow(non_camel_case_types, missing_docs)]
pub mod darwin_ctl {
    pub const AF_SYS_CONTROL: libc::c_int = 2;
    pub const SYSPROTO_EVENT: libc::c_int = 1;
    pub const SYSPROTO_CONTROL: libc::c_int = 2;
    #[repr(C)]
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub struct sockaddr_ctl {
        pub sc_len: libc::c_uchar,
        pub sc_family: libc::c_uchar,
        pub ss_sysaddr: u16,
        pub sc_id: u32,
        pub sc_unit: u32,
        pub sc_reserved: [u32; 5],
    }
}
RUST
cp Cargo.lock "$rust_dir/target/ios-patches/Cargo.lock.orig"
restore_lock() { cp "$rust_dir/target/ios-patches/Cargo.lock.orig" "$rust_dir/Cargo.lock"; }
trap restore_lock EXIT
ios_patch=(--config "patch.crates-io.nix.path=\"$patched\"")

for target in "${targets[@]}"; do
  cargo build --release -j "$jobs" -p cmux-mobile-link-ffi --lib --target "$target" "${ios_patch[@]}"
  exported="$(nm -g "target/$target/release/$lib" 2>/dev/null | grep -c ' T _uniffi_cmux_mobile_link_ffi_' || true)"
  echo "$target: $exported exported uniffi symbols"
  [[ "$exported" -gt 0 ]] || { echo "error: $lib for $target exports no uniffi symbols" >&2; exit 1; }
done

restore_lock
trap - EXIT

# Bindings come from the host library (uniffi library mode).
cargo build --release -j "$jobs" -p cmux-mobile-link-ffi --lib
gen="$(mktemp -d)"
trap 'rm -rf "$gen"' EXIT
cargo run --release -j "$jobs" -p cmux-mobile-link-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library target/release/libcmux_mobile_link_ffi.dylib --language swift --out-dir "$gen"

sources="$cmux_mobile_dir/CmuxMobileKit/Sources/CmuxMobileLinkFFI"
mkdir -p "$sources"
cp "$gen/CmuxMobileLinkFFI.swift" "$sources/CmuxMobileLinkFFI.swift"

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' crates/cmux-mobile-link-ffi/Cargo.toml | head -1)"
frameworks="$cmux_mobile_dir/CmuxMobileKit/Frameworks"
xcf="$frameworks/CmuxMobileLinkFFI.xcframework"
rm -rf "$xcf"
mkdir -p "$xcf"
entries=""
add_slice() {
  local slice="$1" supported="$2" variant="$3" target="$4"
  local fw="$xcf/$slice/$name.framework"
  mkdir -p "$fw/Headers" "$fw/Modules"
  cp "target/$target/release/$lib" "$fw/$name"
  cp "$gen/$name.h" "$fw/Headers/"
  printf 'framework module %s {\n    umbrella header "%s.h"\n    export *\n    module * { export * }\n}\n' \
    "$name" "$name" > "$fw/Modules/module.modulemap"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>dev.cmux.mobile.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
  <key>MinimumOSVersion</key><string>$IPHONEOS_DEPLOYMENT_TARGET</string>
</dict></plist>
PLIST
  plutil -lint "$fw/Info.plist" >/dev/null
  local variant_key=""
  [[ -z "$variant" ]] || variant_key="<key>SupportedPlatformVariant</key><string>$variant</string>"
  entries+="<dict><key>BinaryPath</key><string>$name.framework/$name</string><key>LibraryIdentifier</key><string>$slice</string><key>LibraryPath</key><string>$name.framework</string><key>SupportedArchitectures</key><array><string>arm64</string></array><key>SupportedPlatform</key><string>ios</string>$variant_key</dict>"
}
add_slice ios-arm64 iPhoneOS "" aarch64-apple-ios
add_slice ios-arm64-simulator iPhoneSimulator simulator aarch64-apple-ios-sim
cat > "$xcf/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AvailableLibraries</key><array>$entries</array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict></plist>
PLIST
plutil -lint "$xcf/Info.plist" >/dev/null

if [[ "${SKIP_VERIFY:-0}" != 1 ]]; then
  # Typecheck the bindings against the simulator slice and link a program
  # that calls into the library, so missing system frameworks show up here.
  check="$(mktemp -d)"
  trap 'rm -rf "$gen" "$check"' EXIT
  cat > "$check/main.swift" <<'SWIFT'
print("cmux-mobile-link-ffi \(cmuxMobileVersion())")
SWIFT
  xcrun --sdk iphonesimulator swiftc -target "arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}-simulator" \
    -F "$xcf/ios-arm64-simulator" -framework "$name" -framework Security -framework SystemConfiguration \
    -module-name CmuxMobileLinkFFICheck "$sources/CmuxMobileLinkFFI.swift" "$check/main.swift" -o "$check/cmux-mobile-link-ffi-check"
  echo "verified: bindings typecheck and link for the iOS simulator"
fi

echo "xcframework: $xcf"
echo "swift:       $sources/CmuxMobileLinkFFI.swift"
du -sh "$xcf"/*/ | sed 's/^/  /'
