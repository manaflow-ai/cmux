#!/usr/bin/env bash
out="${FAST_CHECKS_OUT:-/tmp}"
(cd webviews && bun run gallery:build > "$out/gallery-build.log" 2>&1); echo "GALLERY rc=$?"
(cd webviews && bun ../.scratch-gf3/shot.ts) > "$out/shot.log" 2>&1; echo "SHOT rc=$?"; tail -3 "$out/shot.log"
