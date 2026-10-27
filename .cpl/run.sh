#!/bin/bash
# Before (base) and after (this tree) of the Mobile Pairing page with its mock host.
set -euo pipefail
root=$(pwd)
shoot() {
  local label=$1
  (cd "$root/webviews" && node scripts/pages/gen-strings.mjs >/dev/null)
  (cd "$root/webviews" && CMUX_PAGES_DEV_PORT=4190 bunx vp dev --config vite.config.pages-dev.ts --strictPort >/tmp/vite-$label.log 2>&1) &
  local pid=$!
  for _ in $(seq 1 120); do curl -sf http://127.0.0.1:4190/mobile-pairing/ >/dev/null && break; sleep 0.5; done
  (cd "$root/webviews" && node "$root/.cpl/shot.mjs" "http://127.0.0.1:4190/mobile-pairing/?mock" "$label")
  kill $pid; wait $pid 2>/dev/null || true
  pkill -P $pid 2>/dev/null || true
}
shoot after
git fetch -q --depth=1 origin b37a5f3ce3836567774b3e6b666476728f8e9d52
git checkout b37a5f3ce3836567774b3e6b666476728f8e9d52 -- webviews/src/pages/mobile-pairing Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/MobilePairing.xcstrings
shoot before
