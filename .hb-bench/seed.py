"""Seed an acpmux home with N idle local sessions whose summaries are ~5 KB
each (cosmic-gray: 2786 sessions, 14.7 MB list)."""
import json, os, sys
home, n = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.join(home, "sessions"), mode=0o700, exist_ok=True)
pad = "p" * 3650
for i in range(n):
    sid = f"01a16c00-0000-7000-8000-{i:012x}"
    d = os.path.join(home, "sessions", sid)
    os.makedirs(d, mode=0o700, exist_ok=True)
    meta = {"schema": "acpmux.session.v1", "id": sid, "name": f"bench-{i}", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1_792_000_000_000 + i,
            "updatedAt": 1_792_000_000_000 + i, "lastSeq": 0, "eventCount": 0,
            "title": f"Bench chat {i}", "tags": {"pad": {"value": pad}}}
    p = os.path.join(d, "session.json")
    with open(p, "w") as f:
        json.dump(meta, f)
    os.chmod(p, 0o600)
