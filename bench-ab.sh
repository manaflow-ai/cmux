#!/bin/bash
# Runs in the fleet checkout (base + bench + after.patch). Same box: base runs, then the patch, then after runs.
set -u
cd webviews
OUT="${FAST_CHECKS_OUT:-/tmp/nt-bench}"; mkdir -p "$OUT"
echo "box: $(nproc) cpus; $(uname -srm)"; grep -m1 "model name" /proc/cpuinfo || true
for i in 1 2 3; do bun test test/new-tab-template-scale.test.tsx 2>&1 | sed "s/^BENCH /BENCH base /" | tee -a "$OUT/base.log"; done
cd .. && git apply --exclude=webviews/test/new-tab-template-scale.test.tsx bench-after.patch && cd webviews || { echo "PATCH FAILED"; exit 1; }
for i in 1 2 3; do bun test test/new-tab-template-scale.test.tsx 2>&1 | sed "s/^BENCH /BENCH after /" | tee -a "$OUT/after.log"; done
# Bundle sizes: after side now (patched tree), then revert and build base.
# Agent pane bundle (what ships New Tab): after side now (patched tree), then revert and build base.
size() { echo "SIZE $1 pane.js $(wc -c < "$2/pane.js") pane.js.gz $(gzip -9c "$2/pane.js" | wc -c) pane.css $(wc -c < "$2/pane.css") all_js_css $(find "$2" -type f \( -name '*.js' -o -name '*.css' \) -exec cat {} + | wc -c)" | tee -a "$OUT/size.log"; }
cd .. || exit 1
scripts/cmux-next/build-agent-pane-web.sh --out /tmp/nt-pane-after >/tmp/nt-build-after.log 2>&1 && size after /tmp/nt-pane-after || { echo "BUILD after FAILED"; tail -20 /tmp/nt-build-after.log; }
git apply -R --exclude=webviews/test/new-tab-template-scale.test.tsx bench-after.patch || echo "REVERT FAILED"
scripts/cmux-next/build-agent-pane-web.sh --out /tmp/nt-pane-base >/tmp/nt-build-base.log 2>&1 && size base /tmp/nt-pane-base || { echo "BUILD base FAILED"; tail -20 /tmp/nt-build-base.log; }
