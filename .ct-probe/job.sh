#!/usr/bin/env bash
echo "host $(hostname) nproc $(nproc)"
bash .ct-probe/run2.sh off none off none
echo "== plain (fix, minified, nightly flags) load $(cut -d' ' -f1 /proc/loadavg)"
(cd webviews && bun bench/composer-typing.bench.ts --engines webkit --mode L0 --lengths 60 --repeat 3 2>&1 | grep -E "^COMPOSER-TYPING" | cut -c1-600)
bash .ct-probe/run.sh wk-off wk
