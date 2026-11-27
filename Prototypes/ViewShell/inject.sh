#!/usr/bin/env bash
# Live code patch (README.md, "Live code"): compiles the edited Swift files of the view shell
# against its Debug build's settings, links only those files into a dylib, signs it, and drops it
# into the live folder a running `cmux-view-shell --live DIR` watches. The shell interposes the
# patch's functions and redraws: no relaunch. Run it where the shell runs, or compile on a fleet
# Mac and copy the dylib into the folder (it is the same file either way).
#
#   Prototypes/ViewShell/inject.sh --live ~/.cache/cmux-view-shell/live Sources/ViewShell/Badge.swift
#
# The patch also takes, with no need to name them, every Swift file of the module the running
# build did not compile (a new file: its types and functions live only in the patch, and the
# edited files that use them link against them there) and every file changed since that build
# (an earlier patch's file, so each patch holds all of the new code and none of it goes stale).
# The build is the package's Debug build (`.build/debug`); CMUX_VIEW_SHELL_BUILD names another.
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
# What the running build compiled (an object per file in `ViewShell.build`) and when: a file with
# no object is new, and one newer than the executable changed since.
build="${CMUX_VIEW_SHELL_BUILD:-$package/.build/debug}"
compiled="$build/ViewShell.build"
executable="$build/cmux-view-shell"
names=()
for file in "${files[@]}"; do names+=("$(basename "$file" .swift)"); done
if [[ -d "$compiled" && -f "$executable" ]]; then
  for file in "${all[@]}"; do
    name="$(basename "$file" .swift)"
    why=""
    if [[ ! -f "$compiled/$name.swift.o" ]]; then why="new since the build"
    elif [[ "$file" -nt "$executable" ]]; then why="changed since the build"; fi
    [[ -n "$why" && " ${names[*]} " != *" $name "* ]] || continue
    names+=("$name")
    echo "inject.sh: also $name.swift ($why)"
  done
else
  echo "inject.sh: no Debug build at $build; the patch holds only the files named" >&2
fi
objects=()
for name in "${names[@]}"; do
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
