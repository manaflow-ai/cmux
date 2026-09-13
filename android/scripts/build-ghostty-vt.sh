#!/usr/bin/env bash
# Builds libghostty-vt.so for Android (arm64-v8a + x86_64) from the ghostty
# submodule and installs it into android/core/ghostty-vt/src/main/jniLibs/.
#
# This is NOT part of the normal Gradle/Android Studio build — routine
# `./gradlew assembleDebug` links the prebuilt .so files this script produces,
# so every dev's inner loop stays fast and doesn't need Zig or the Android NDK
# configured. Run this script manually (and commit the resulting .so files)
# whenever the `ghostty` submodule pin advances — mirrors the discipline for
# rebuilding GhosttyKit.xcframework on the Mac/iOS side (see the cmux-ghostty
# skill). If you forget, Android's terminal rendering silently keeps using
# the previous ghostty-vt build until this is re-run.
#
# Requires: zig (https://ziglang.org, tested with 0.16.0) and the Android NDK
# (set ANDROID_NDK_HOME, or ANDROID_HOME/ANDROID_SDK_ROOT with an `ndk/<ver>`
# subdirectory — see ghostty/pkg/android-ndk/build.zig for the exact lookup).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"
JNI_LIBS_DIR="$REPO_ROOT/android/core/ghostty-vt/src/main/jniLibs"

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found on PATH (https://ziglang.org)" >&2
    exit 1
fi

if [[ -z "${ANDROID_NDK_HOME:-}" && -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    echo "error: set ANDROID_NDK_HOME, or ANDROID_HOME/ANDROID_SDK_ROOT with an ndk/<version> subdir" >&2
    exit 1
fi

# Resolve the NDK dir the same way ghostty/pkg/android-ndk/build.zig does, so
# we can shell out to its bundled llvm-readelf below (used to read each built
# library's own embedded SONAME — see the note on that below).
ndk_dir="${ANDROID_NDK_HOME:-}"
if [[ -z "$ndk_dir" ]]; then
    sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    ndk_dir="$(ls -d "$sdk_dir"/ndk/*/ 2>/dev/null | sort -V | tail -1)"
fi
if [[ -z "$ndk_dir" || ! -d "$ndk_dir" ]]; then
    echo "error: could not resolve an NDK directory" >&2
    exit 1
fi
readelf="$(find "$ndk_dir/toolchains/llvm/prebuilt" -maxdepth 3 -name "llvm-readelf" -print -quit)"
if [[ -z "$readelf" ]]; then
    echo "error: llvm-readelf not found under $ndk_dir/toolchains/llvm/prebuilt" >&2
    exit 1
fi

# zig target triple -> Android ABI name (jniLibs directory). Parallel arrays,
# not an associative array, for portability with macOS's stock bash 3.2.
TARGET_TRIPLES=("aarch64-linux-android" "x86_64-linux-android")
TARGET_ABIS=("arm64-v8a" "x86_64")

for i in "${!TARGET_TRIPLES[@]}"; do
    target="${TARGET_TRIPLES[$i]}"
    abi="${TARGET_ABIS[$i]}"
    echo "==> Building libghostty-vt for $target ($abi)"

    build_dir="$(mktemp -d)"
    (
        cd "$GHOSTTY_DIR"
        zig build -Demit-lib-vt -Dtarget="$target" -Doptimize=ReleaseFast --prefix "$build_dir"
    )

    so_path="$(find "$build_dir" -name "libghostty-vt.so" -print -quit)"
    if [[ -z "$so_path" ]]; then
        echo "error: libghostty-vt.so not found under $build_dir after building for $target" >&2
        echo "       (zig-out layout may have changed — inspect $build_dir manually)" >&2
        exit 1
    fi

    # Zig's addLibrary() bakes a versioned SONAME into the .so itself (e.g.
    # "libghostty-vt.so.0", not the plain "libghostty-vt.so" build filename).
    # Two things both key off that embedded SONAME, not the on-disk filename
    # at link time: (a) Android's APK packaging only ships native libs whose
    # filename ends in exactly ".so" (a ".so.0" file is silently dropped from
    # the APK), and (b) libghostty_vt_jni.so's NEEDED entry is copied from
    # this SONAME at link time, so at runtime the dynamic linker looks for a
    # file with that exact versioned name. Left alone, that combination means
    # the dependency never makes it into the APK and the app crashes with
    # UnsatisfiedLinkError on first load. Fix: patch the embedded SONAME back
    # to a plain "libghostty-vt.so" before installing, so both packaging and
    # the runtime NEEDED lookup agree with the shipped filename. This is a
    # safe in-place fix: SONAME is a null-terminated string in .dynstr, and
    # the target name is never longer than Zig's versioned one, so it's a
    # same-length byte replacement (padded with extra NULs), not a relink.
    target_soname="libghostty-vt.so"
    soname="$("$readelf" -d "$so_path" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
    if [[ -z "$soname" ]]; then
        echo "error: could not read SONAME from $so_path" >&2
        exit 1
    fi
    if [[ "$soname" != "$target_soname" ]]; then
        if [[ ${#target_soname} -gt ${#soname} ]]; then
            echo "error: embedded SONAME '$soname' is shorter than '$target_soname' — the in-place patch below needs a patchelf-style relink instead" >&2
            exit 1
        fi
        python3 - "$so_path" "$soname" "$target_soname" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old_b = (old + "\0").encode()
new_b = new.encode() + b"\0" * (len(old_b) - len(new.encode()))
assert len(old_b) == len(new_b)
with open(path, "rb") as f:
    data = f.read()
count = data.count(old_b)
if count != 1:
    print(f"error: expected exactly 1 occurrence of {old_b!r}, found {count}", file=sys.stderr)
    sys.exit(1)
with open(path, "wb") as f:
    f.write(data.replace(old_b, new_b, 1))
PYEOF
        soname="$target_soname"
        patched_soname="$("$readelf" -d "$so_path" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
        if [[ "$patched_soname" != "$target_soname" ]]; then
            echo "error: SONAME patch didn't take — readelf now reports '$patched_soname'" >&2
            exit 1
        fi
    fi

    dest_dir="$JNI_LIBS_DIR/$abi"
    mkdir -p "$dest_dir"
    rm -f "$dest_dir"/libghostty-vt.so*
    cp "$so_path" "$dest_dir/$soname"
    echo "==> Installed $dest_dir/$soname"
    ls -lh "$dest_dir/$soname"

    rm -rf "$build_dir"
done

echo "==> Done. Review and commit android/core/ghostty-vt/src/main/jniLibs/*/libghostty-vt.so"
