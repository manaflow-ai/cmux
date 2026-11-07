#!/usr/bin/env bash
set -uo pipefail
O=316d139feaf89d9ab7c99dc9cffdce59309bef93
N=6b39b4c2ce1d6a301c106159c859d5b1d303eb62
B=$(mktemp -d /tmp/swapbins.XXXXXX)
for pair in "old:$O" "new:$N"; do
  curl -sfL -o "$B/${pair%%:*}" "https://files.cmux.com/cmux-tui/${pair#*:}/cmux-tui-x86_64-unknown-linux-musl" || { echo "download ${pair} failed"; exit 2; }
done
chmod +x "$B/old" "$B/new"
sha256sum "$B/old" "$B/new"; "$B/old" --version; "$B/new" --version
uname -a; nproc
OUT="${FAST_CHECKS_OUT:-/tmp/swap-out}"; mkdir -p "$OUT"
python3 scripts/cmux-next/daemon-swap-check.py --old "$B/old" --new "$B/new" --phases terminals --terminals 4 > "$OUT/swap-check.json"; a=$?
cat "$OUT/swap-check.json"
python3 .issues-swap/restart_route.py "$B/old" "$B/new" > "$OUT/restart-route.json"; b=$?
cat "$OUT/restart-route.json"
echo "RESULT swap-check exit=$a restart-route exit=$b"
exit $(( a | b ))
