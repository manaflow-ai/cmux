#!/bin/bash
# Scratch for the fleet job only (not committed): measures the spacing reference at this tree and at
# the 2026-10-30 nightly's feat-cmux-next commit (8f5dfe06ee58c901a55e716d5b8a6ffcddd5836a), made by
# applying .oct30.patch (base -> that commit, webviews/ only) to a copy of this tree.
set -uo pipefail
root=$(pwd)
run() {
  CMUX_BROWSER_TESTS=1 CMUX_TRANSCRIPT_SPACING_LOG=1 bun test test/transcript-spacing-reference.test.ts 2>&1 | grep -v -E '^\s*$' | tail -40
}
if [ "${1:-}" != "old-only" ]; then
  echo "=== BASE"
  (cd "$root/webviews" && run)
fi
[ "${1:-}" = "base-only" ] && exit 0
rm -rf /tmp/oct30 && mkdir -p /tmp/oct30
rsync -a --exclude node_modules --exclude .git "$root"/ /tmp/oct30/
(cd /tmp/oct30 && git apply --whitespace=nowarn .oct30.patch) || { echo "patch failed"; exit 1; }
ln -s "$root/webviews/node_modules" /tmp/oct30/webviews/node_modules
echo "=== OCT30"
(cd /tmp/oct30/webviews && run)
