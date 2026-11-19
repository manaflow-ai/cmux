#!/usr/bin/env bash
# Scratch (not committed): tests + cmux hosts check wall-time measurement on the Linux box.
set -u
cd cmux-tui
echo "== tests"
cargo test -q -p cmux-config hosts 2>&1 | grep -E "test result|FAILED|panicked|^error" | head -20
cargo test -q -p cmux-config schema 2>&1 | grep -E "test result|FAILED|panicked|^error" | head -20
cargo test -q -p cmux-tui --lib hosts 2>&1 | grep -E "test result|FAILED|panicked|^error|^test " | head -40
echo "== build"
cargo build -q -p cmux-tui --bin cmux-tui 2>&1 | grep -E "^error" | head
B=$PWD/target/debug/cmux-tui
ls -la "$B" || exit 1
W=$(mktemp -d)
# A fake ssh server (banner) and a fake web server (not ssh), each on its own port.
cat > "$W/srv.py" <<'P'
import socket, sys, threading
banner = sys.argv[1].encode()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1024)
print(s.getsockname()[1], flush=True)
def serve(c):
    try: c.sendall(banner)
    finally: c.close()
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
P
python3 "$W/srv.py" $'SSH-2.0-OpenSSH_9.6\r\n' > "$W/ssh.port" & SSHPID=$!
python3 "$W/srv.py" $'HTTP/1.1 400 Bad Request\r\n\r\n' > "$W/web.port" & WEBPID=$!
sleep 1
SSHP=$(cat "$W/ssh.port"); WEBP=$(cat "$W/web.port")
CLOSED=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mk() { # N MODE -> config
  python3 - "$1" "$2" "$SSHP" "$WEBP" "$CLOSED" > "$W/cfg.json" <<'P'
import json, sys
n, mode, ssh, web, closed = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
kinds = {"reach": [f"ssh://127.0.0.1:{ssh}"], "down": [f"ssh://127.0.0.1:{web}"],
         "refused": [f"ssh://127.0.0.1:{closed}"], "blackhole": ["ssh://10.255.255.1:22"],
         "nodns": ["ssh://no-such-host.invalid"],
         "fallback": [f"ssh://127.0.0.1:{closed}", f"ssh://127.0.0.1:{ssh}"]}
order = ["reach", "down", "refused", "blackhole", "nodns", "fallback"]
hosts = []
for i in range(n):
    k = order[i % len(order)] if mode == "mixed" else mode
    hosts.append({"label": f"{k}-{i}", "endpoints": kinds[k]})
print(json.dumps({"machines": {"hosts": hosts}}))
P
}
export CMUX_NEXT_CONFIG_FILE="$W/cfg.json"
echo "== sample (6 kinds)"
mk 6 mixed; "$B" hosts list; "$B" hosts check --timeout 2; "$B" hosts check --timeout 2 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("wallMs", d["wallMs"], [(h["label"], h["status"], h["endpoint"]) for h in d["hosts"]])'
echo "== wall time (ms), timeout 3 s"
for mode in reach mixed; do
  for n in 1 10 50 200; do
    mk $n $mode
    t0=$(date +%s%N); "$B" hosts check --json > "$W/out.json"; t1=$(date +%s%N)
    python3 -c "import json; d=json.load(open('$W/out.json')); from collections import Counter; print('$mode', $n, 'process_ms', ($t1-$t0)//1000000, 'wallMs', d['wallMs'], dict(Counter(h['status'] for h in d['hosts'])))"
  done
done
kill $SSHPID $WEBPID 2>/dev/null
