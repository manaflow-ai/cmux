#!/bin/sh
# DaemonWireTypesPlugin's interpreter pick: pick-python.sh GENERATOR OUT runs `PYTHON -I -B GENERATOR --out OUT`
# with the first Python 3.10+ it finds (cmux-tui/bindings/codegen needs dataclass slots).
#
# Xcode and SwiftPM run plugins with PATH=/usr/bin:/bin, whose python3 on macOS is 3.9, so the fixed folders come
# first: Homebrew, /usr/local, python.org and ~/.local/bin (uv's pinned Python). Each folder counts python3 and
# every versioned python3.NN: Homebrew's python@3.13 as another formula's dependency links only python3.13
# (aws-m4pro-1 and -3, 2026-11-27), and uv links only python3.15. PATH is the fallback, with the same names.
#
# This is a file, not `sh -c TEXT`: SwiftPM echoes a failed prebuild command's arguments, so inline script text
# put its own "needs Python" line into every plugin failure's log, and a codegen error read as a missing Python.
generator=$1 out=$2

probe() {
    for py in "$@"; do
        [ -x "$py" ] || continue
        "$py" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || continue
        exec "$py" -I -B "$generator" --out "$out"
    done
}

for dir in /opt/homebrew/bin /usr/local/bin /Library/Frameworks/Python.framework/Versions/Current/bin \
    ${HOME:+"$HOME/.local/bin"}; do
    probe "$dir"/python3 "$dir"/python3.[1-9][0-9]
done
IFS=:
for dir in $PATH; do
    [ -n "$dir" ] && probe "$dir"/python3 "$dir"/python3.[1-9][0-9]
done
echo "error: DaemonWireTypesPlugin needs Python 3.10+ in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin or PATH (brew install python)" >&2
exit 1
