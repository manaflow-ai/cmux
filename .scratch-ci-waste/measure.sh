#!/usr/bin/env bash
# Times each part of "Pushed commits add no violations" on a fresh depth-2 clone,
# as the checks job's checkout leaves it. Usage: measure.sh <head sha> <before sha>
set -uo pipefail
head="$1" before="$2" from=342462ca6ee97db1d23f013ad0d58dc942673c82
url=https://github.com/manaflow-ai/cmux.git
src="$PWD"
t() { local label="$1"; shift; local s; s=$(date +%s.%N); "$@" >/tmp/m.out 2>&1; local rc=$?; printf '%-48s %6.1fs rc=%s\n' "$label" "$(echo "$(date +%s.%N) - $s" | bc)" "$rc"; tail -2 /tmp/m.out | cut -c1-160; }
fresh() { # <dir>: a depth-2 clone of <head>, like actions/checkout fetch-depth: 2
  rm -rf "$1"; git init -q "$1"; git -C "$1" remote add origin "$url"
  git -C "$1" fetch -q --no-tags --depth=2 origin "$head" && git -C "$1" checkout -q --detach "$head"
  cp "$src/scripts/cmux-next/prepush-gate.py" "$1/scripts/cmux-next/prepush-gate.py"
}
sweep() { (cd "$1" && python3 -I scripts/cmux-next/prepush-gate.py --only sidebar --commits "$from..HEAD"); }
gate() { (cd "$1" && python3 -I scripts/cmux-next/prepush-gate.py --commits "$2"); }

echo "== A: today's step (push)"
t "depth-2 checkout" fresh /tmp/a
t "fetch --deepen=2000" git -C /tmp/a fetch --no-tags --quiet --deepen=2000 origin "$head"
t "sweep" sweep /tmp/a
t "fetch --depth=200 head before" git -C /tmp/a fetch --no-tags --quiet --depth=200 origin "$head" "$before"
t "gate --commits before..HEAD" gate /tmp/a "$before..HEAD"

echo "== B: deepen only as far as the sweep base, blobs left out"
t "depth-2 checkout" fresh /tmp/b
t "fetch --shallow-exclude-ish (deepen loop 64)" bash -c '
  for i in $(seq 1 20); do git -C /tmp/b cat-file -e '"$from"'^{commit} 2>/dev/null && exit 0
    git -C /tmp/b fetch --no-tags --quiet --deepen=64 origin '"$head"' || exit 1; done; exit 1'
t "sweep" sweep /tmp/b
t "gate --commits before..HEAD (no refetch)" gate /tmp/b "$before..HEAD"

echo "== C: blobless deepen=2000"
t "depth-2 checkout" fresh /tmp/c
t "fetch --filter=blob:none --deepen=2000" git -C /tmp/c fetch --no-tags --quiet --filter=blob:none --deepen=2000 origin "$head"
t "sweep" sweep /tmp/c
t "gate --commits before..HEAD (no refetch)" gate /tmp/c "$before..HEAD"

echo "== D: shallow-since the sweep base's commit date"
t "depth-2 checkout" fresh /tmp/d
t "fetch --shallow-since" git -C /tmp/d fetch --no-tags --quiet --shallow-since=2026-10-26T23:00:00-0700 origin "$head"
t "is sweep base present" git -C /tmp/d cat-file -e "$from^{commit}"
t "sweep" sweep /tmp/d
git -C /tmp/d rev-list --count HEAD
