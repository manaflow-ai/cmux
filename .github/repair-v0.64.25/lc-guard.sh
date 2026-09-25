#!/usr/bin/env bash
# Fails when any Mach-O slice in the bundle has an LC_RPATH or dylib load
# command that points at an absolute path outside /usr/lib and /System.
set -euo pipefail
APP="$1"
bad=0
checked=0
while IFS= read -r -d '' f; do
  case "$(/usr/bin/file -b "$f")" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
  archs="$(/usr/bin/lipo -archs "$f")"
  for arch in $archs; do
    while IFS=$'\t' read -r cmd target; do
      case "$target" in
        @*|/usr/lib|/usr/lib/*|/System/*) ;;
        *) echo "::error::${f#"$APP"/} [$arch] $cmd $target"; bad=1 ;;
      esac
    done < <(/usr/bin/otool -arch "$arch" -l "$f" | awk '
      /^ *cmd LC_(RPATH|LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB)$/ { cmd = $2; next }
      cmd != "" && /^ *(path|name) / {
        line = $0
        sub(/^ *(path|name) /, "", line)
        sub(/ \(offset [0-9]+\)$/, "", line)
        print cmd "\t" line
        cmd = ""
      }')
  done
done < <(find "$APP" -type f -print0)
echo "checked $checked Mach-O files"
[ "$bad" -eq 0 ]
