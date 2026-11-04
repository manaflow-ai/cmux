#!/usr/bin/env bash
# Live code patch (README.md, "Live code"): compiles the edited Swift files of the view shell
# against its Debug build's settings, links only those files into a dylib, signs it, and drops it
# into the live folder a running `cmux-view-shell --live DIR` watches. The shell interposes the
# patch's functions and redraws: no relaunch. Run it where the shell runs, or compile on a fleet
# Mac and copy the dylib into the folder (it is the same file either way).
#
#   Prototypes/ViewShell/inject.sh --live ~/.cache/cmux-view-shell/live Sources/ViewShell/Badge.swift
#
# CMUX_LIVE_CODE_SIGN_IDENTITY signs with that identity (a Developer ID for a signed host);
# the default is ad hoc, which an unsigned Debug shell accepts.
set -euo pipefail

package="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
live=""
files=()
while (($#)); do
  case "$1" in
    --live) live="$2"; shift 2 ;;
    *) files+=("$1"); shift ;;
  esac
done
if [[ -z "$live" || ${#files[@]} -eq 0 ]]; then
  echo "usage: inject.sh --live DIR FILE.swift..." >&2
  exit 64
fi

sources="$package/Sources/ViewShell"
target="$(uname -m)-apple-macos14.0"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-view-shell-patch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
started=$(python3 -c 'import time; print(f"{time.time():.3f}")')

# The module's every file, as SwiftPM's Debug build compiles it; only the edited ones are linked.
all=("$sources"/*.swift)
(cd "$work" && xcrun swiftc -c "${all[@]}" -module-name ViewShell -target "$target" \
  -Onone -g -enable-testing -DDEBUG -DSWIFT_PACKAGE -swift-version 6)
objects=()
for file in "${files[@]}"; do
  name="$(basename "$file" .swift)"
  [[ "$name" == main || "$name" == LiveCode ]] && { echo "inject.sh: $name.swift holds the shell's own loop; rebuild for it" >&2; exit 65; }
  objects+=("$work/$name.o")
done

patch="patch-$(date +%s)-$$.dylib"
xcrun swiftc -emit-library "${objects[@]}" -o "$work/$patch" -target "$target" -module-name ViewShellPatch \
  -Xlinker -undefined -Xlinker dynamic_lookup
codesign --force --sign "${CMUX_LIVE_CODE_SIGN_IDENTITY:--}" "$work/$patch" 2>/dev/null
mkdir -p "$live"
# Move into place in one step, so the shell never reads a half-written file.
mv "$work/$patch" "$live/.$patch" && mv "$live/.$patch" "$live/$patch"
echo "inject.sh: $live/$patch (started=$started)"
