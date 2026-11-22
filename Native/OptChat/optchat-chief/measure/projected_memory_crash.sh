#!/usr/bin/env bash
# Local proof (one Linux host, real FUSE projection from cmux-projection's conformance_mount):
# a Chief memory SQLite file handed out into SOURCE, projected at MNT, written there in WAL with
# synchronous=FULL, the writer and then the mount daemon killed -9 mid-write, the projection
# mounted again over the same STATE: every commit that returned is there and integrity_check is ok;
# after the take-in copy-up the source can go away.
set -euo pipefail
BIN=${1:?"conformance_mount binary (cd cmux-tui && cargo build -p cmux-projection --example conformance_mount)"}
W=$(mktemp -d)
SRC=$W/source MNT=$W/mnt STATE=$W/state
mkdir -p "$SRC" "$MNT" "$STATE"
python3 -I - "$W/orig.sqlite3" "$SRC/memory.sqlite3" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE log(id INTEGER PRIMARY KEY, text TEXT)")
c.executemany("INSERT INTO log(text) VALUES (?)", [("remember the blue door",)] + [("filler %d" % i * 40,) for i in range(5000)])
c.commit(); c.execute("VACUUM INTO ?", (sys.argv[2],)); c.close()
d = sqlite3.connect(sys.argv[2]); d.execute("PRAGMA journal_mode=DELETE"); d.close()
EOF
mount_it() {
  "$BIN" "$SRC" "$MNT" "$STATE" > "$W/mount.out" 2> "$W/mount.err" &
  MPID=$!
  for _ in $(seq 100); do grep -q mounted "$W/mount.out" 2>/dev/null && return 0; sleep 0.1; done
  echo "mount did not come up"; cat "$W/mount.err"; exit 1
}
mount_it
echo "mounted pid $MPID: $(grep " $MNT " /proc/self/mountinfo | awk '{for(i=1;i<=NF;i++) if($i=="-") print $(i+1)}')"
# Take-in: a write open + fsync copies the store whole into the upper layer.
python3 -I -c "import os,sys; fd=os.open(sys.argv[1], os.O_RDWR); os.fsync(fd); os.close(fd)" "$MNT/memory.sqlite3"
# The writer: one row per commit, prints the id after commit returns.
python3 -I - "$MNT/memory.sqlite3" > "$W/committed.txt" <<'EOF' &
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
print("mode", c.execute("PRAGMA journal_mode=WAL").fetchone()[0], flush=True)
c.execute("PRAGMA synchronous=FULL")
i = 0
while True:
    i += 1
    c.execute("BEGIN"); c.execute("INSERT INTO log(text) VALUES (?)", ("turn %d " % i + "x" * 2000,)); c.execute("COMMIT")
    print(i, flush=True)
EOF
WPID=$!
sleep 3
kill -9 "$WPID"; kill -9 "$MPID"; wait "$WPID" 2>/dev/null || true; wait "$MPID" 2>/dev/null || true
fusermount3 -u -z "$MNT" 2>/dev/null || true
LAST=$(grep -E '^[0-9]+$' "$W/committed.txt" | tail -1)
echo "writer: $(head -1 "$W/committed.txt"), last commit that returned: $LAST; writer and mount daemon killed -9"
# The source goes away: B must not need A after the take-in.
mv "$SRC/memory.sqlite3" "$W/source-gone.sqlite3"
mount_it
RC=0
python3 -I - "$MNT/memory.sqlite3" "$LAST" <<'EOF' || RC=$?
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
ok = c.execute("PRAGMA integrity_check").fetchone()[0]
turns = c.execute("SELECT count(*) FROM log WHERE text LIKE 'turn %'").fetchone()[0]
door = c.execute("SELECT count(*) FROM log WHERE text = 'remember the blue door'").fetchone()[0]
last = int(sys.argv[2])
print(f"after remount, source gone: integrity_check={ok} turns={turns} (>= {last} returned) blue_door={door}")
sys.exit(0 if ok == "ok" and turns >= last and door == 1 else 1)
EOF
kill "$MPID"; wait "$MPID" 2>/dev/null || true
echo "PROOF rc=$RC dir=$W"
exit $RC
