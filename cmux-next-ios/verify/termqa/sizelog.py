"""M-SIZELOG summarizer (ACCEPTANCE.md G-07): resizes, mirror resets and replays from a
simulator's unified log, each with its cause.

    python3 sizelog.py UDID [--last 30m] [--json OUT]

Reads subsystem dev.cmux.mobile, categories terminal-sizing (screen: `resize CxR cause=...`,
`mirror reset cause=...`, `replay done bytes=N ms=M`) and terminal (session:
`mirror reset cause=attach|reattach|resized-event`).
"""
import collections
import json
import re
import subprocess
import sys


def read(udid, last):
    pred = 'subsystem == "dev.cmux.mobile" AND (category == "terminal-sizing" OR category == "terminal")'
    out = subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "show", "--style", "compact", "--last", last,
                          "--predicate", pred], capture_output=True, text=True).stdout
    return out.splitlines()


def summarize(lines):
    resizes, resets, replays = collections.Counter(), collections.Counter(), []
    events = []
    for line in lines:
        m = re.search(r"resize (\d+)x(\d+) cause=(\S+)", line)
        if m:
            resizes[m.group(3)] += 1
            events.append({"kind": "resize", "size": f"{m.group(1)}x{m.group(2)}", "cause": m.group(3), "line": line[:23]})
            continue
        m = re.search(r"mirror reset cause=(\S+)", line)
        if m and "session's replay follows" not in line:
            resets[m.group(1)] += 1
            events.append({"kind": "reset", "cause": m.group(1), "line": line[:23]})
            continue
        m = re.search(r"replay done bytes=(\d+) ms=(\d+)", line)
        if m:
            replays.append({"bytes": int(m.group(1)), "ms": int(m.group(2))})
            events.append({"kind": "replay", **replays[-1], "line": line[:23]})
    return {"resizes": dict(resizes), "resets": dict(resets), "replays": len(replays),
            "replay_ms_max": max((r["ms"] for r in replays), default=None), "events": events}


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    last = sys.argv[sys.argv.index("--last") + 1] if "--last" in sys.argv else "30m"
    s = summarize(read(sys.argv[1], last))
    if "--json" in sys.argv:
        json.dump(s, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)
    print(json.dumps({k: v for k, v in s.items() if k != "events"}))
