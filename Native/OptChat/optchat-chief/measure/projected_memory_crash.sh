#!/usr/bin/env bash
# Local proof (one Linux host, a real FUSE projection from cmux-projection's conformance_mount) of
# memory_place.rs's take-in: a Chief memory handed out into SOURCE (VACUUM INTO, sha256 noted) is
# projected at MNT; the take-in copies it off the mount to a temp file on local disk the way
# `take_in` does, and the mount daemon is killed -9 mid-copy: nothing is placed. The projection
# comes up again over the same STATE, the copy runs whole, its sha256 matches the hand-out and it
# is renamed into place; the source goes away; the local copy passes integrity_check and has the
# blue-door row. Then the live memory, on local disk as on any Chief, takes a writer killed -9
# mid-commit: every commit that returned is there.
set -euo pipefail
BIN=${1:?"conformance_mount binary (cd cmux-tui && cargo build -p cmux-projection --example conformance_mount)"}
W=$(mktemp -d)
SRC=$W/source MNT=$W/mnt STATE=$W/state LOCAL=$W/optchat
mkdir -p "$SRC" "$MNT" "$STATE" "$LOCAL"
WANT=$(python3 -I - "$W/orig.sqlite3" "$SRC/memory.sqlite3" <<'EOF'
import hashlib, sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE log(id INTEGER PRIMARY KEY, text TEXT)")
c.executemany("INSERT INTO log(text) VALUES (?)", [("remember the blue door",)] + [("filler %d " % i * 40,) for i in range(20000)])
c.commit(); c.execute("VACUUM INTO ?", (sys.argv[2],)); c.close()
print(hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest())
EOF
)
echo "hand-out: $(stat -c %s "$SRC/memory.sqlite3") bytes, sha256 $WANT"
mount_it() {
  "$BIN" "$SRC" "$MNT" "$STATE" > "$W/mount.out" 2> "$W/mount.err" &
  MPID=$!
  for _ in $(seq 100); do grep -q mounted "$W/mount.out" 2>/dev/null && return 0; sleep 0.1; done
  echo "mount did not come up"; cat "$W/mount.err"; exit 1
}
# take_in's copy: byte for byte to NAME.tmp-take-in, fsync, check sha256, rename. $2 = seconds
# to pause after each 64 KiB (so a kill lands mid-copy).
take_in() {
  python3 -I - "$MNT/memory.sqlite3" "$LOCAL/memory.sqlite3" "$WANT" "$1" <<'EOF'
import hashlib, os, sys, time
src, dst, want, pause = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
tmp = dst + ".tmp-take-in"
if os.path.exists(tmp): os.remove(tmp)
h = hashlib.sha256()
with open(src, "rb") as f, open(tmp, "xb") as g:
    while chunk := f.read(65536):
        g.write(chunk); h.update(chunk); time.sleep(pause)
    g.flush(); os.fsync(g.fileno())
if h.hexdigest() != want:
    os.remove(tmp); sys.exit(f"sha256 {h.hexdigest()} != hand-out {want}: not placed")
os.rename(tmp, dst)
d = os.open(os.path.dirname(dst), os.O_RDONLY); os.fsync(d); os.close(d)
print("placed")
EOF
}
mount_it
echo "mounted pid $MPID: $(grep " $MNT " /proc/self/mountinfo | awk '{for(i=1;i<=NF;i++) if($i=="-") print $(i+1)}')"
take_in 0.05 > "$W/take1.out" 2>&1 &
TPID=$!
sleep 1
kill -9 "$MPID"; wait "$MPID" 2>/dev/null || true
fusermount3 -u -z "$MNT" 2>/dev/null || true
wait "$TPID" && { echo "FAIL: the take-in finished although its mount died"; exit 1; }
PLACED=no; [ -e "$LOCAL/memory.sqlite3" ] && PLACED=yes
echo "mount daemon killed -9 mid-copy: take-in failed ($(tail -1 "$W/take1.out" | cut -c1-80)), store placed: $PLACED"
[ "$PLACED" = no ] || exit 1
mount_it
take_in 0
kill "$MPID"; wait "$MPID" 2>/dev/null || true
fusermount3 -u -z "$MNT" 2>/dev/null || true
# The source and the mount go away: the memory needs neither now.
mv "$SRC/memory.sqlite3" "$W/source-gone.sqlite3"
python3 -I - "$LOCAL/memory.sqlite3" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
ok = c.execute("PRAGMA integrity_check").fetchone()[0]
door = c.execute("SELECT count(*) FROM log WHERE text = 'remember the blue door'").fetchone()[0]
print(f"taken in, source and mount gone: integrity_check={ok} blue_door={door}")
sys.exit(0 if ok == "ok" and door == 1 else 1)
EOF
# The live memory on local disk: a writer killed -9 mid-commit.
python3 -I - "$LOCAL/memory.sqlite3" > "$W/committed.txt" <<'EOF' &
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA synchronous=FULL")
i = 0
while True:
    i += 1
    c.execute("BEGIN"); c.execute("INSERT INTO log(text) VALUES (?)", ("turn %d " % i + "x" * 2000,)); c.execute("COMMIT")
    print(i, flush=True)
EOF
WPID=$!
sleep 2
kill -9 "$WPID"; wait "$WPID" 2>/dev/null || true
LAST=$(grep -E '^[0-9]+$' "$W/committed.txt" | tail -1)
python3 -I - "$LOCAL/memory.sqlite3" "$LAST" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
ok = c.execute("PRAGMA integrity_check").fetchone()[0]
turns = c.execute("SELECT count(*) FROM log WHERE text LIKE 'turn %'").fetchone()[0]
last = int(sys.argv[2])
print(f"writer killed -9: integrity_check={ok} turns={turns} (>= {last} returned)")
sys.exit(0 if ok == "ok" and turns >= last else 1)
EOF
echo "PROOF ok dir=$W"
