"""Reads the DEBUG terminal probe (`-CmuxMobileTermProbe`, TerminalDevProbe.swift) from a simulator.

    python3 termprobe.py echo UDID BUNDLE [--since EPOCH] [--json OUT]
        echo latency samples (M-ECHO, G-08): n, p50, p95, p99, max in ms
    python3 termprobe.py export UDID BUNDLE OUTDIR
        asks every open terminal for its whole text (M-INTEG, G-09) and copies
        Documents/termprobe/*.txt to OUTDIR
    python3 termprobe.py crc FILE
        checks a crcgen.py run in an exported text: every id once and in order,
        each row's crc, and the TOTAL line

Launch the app with `-CmuxMobileTermProbe` (simctl launch UDID BUNDLE -CmuxMobileTermProbe ...).
For echo under a flood, type a byte the flood never prints (`~` or `^`).
"""
import binascii
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time


def container(udid, bundle):
    return subprocess.run(["xcrun", "simctl", "get_app_container", udid, bundle, "data"],
                          capture_output=True, text=True, check=True).stdout.strip()


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, max(0, -(-int(p * len(s) * 1000) // 1000) - 1))] if s else None


def echo(udid, bundle, since=0.0, out=None):
    path = os.path.join(container(udid, bundle), "Documents/termprobe/echo.jsonl")
    rows = [json.loads(line) for line in open(path)] if os.path.exists(path) else []
    ms = [r["ms"] for r in rows if r["t"] >= since]
    summary = {"n": len(ms), "p50": pct(ms, 0.5), "p95": pct(ms, 0.95), "p99": pct(ms, 0.99), "max": max(ms) if ms else None}
    if out:
        json.dump({"summary": summary, "samples": [r for r in rows if r["t"] >= since]}, open(out, "w"), indent=1)
    return summary


def export(udid, bundle, outdir):
    docs = os.path.join(container(udid, bundle), "Documents/termprobe")
    before = {f: os.path.getmtime(f) for f in glob.glob(os.path.join(docs, "*.txt"))}
    # Arm the waiter for the app's reply first: the app answers within milliseconds.
    waiter = subprocess.Popen(["xcrun", "simctl", "spawn", udid, "notifyutil", "-1", "dev.cmux.mobile.termprobe.exported"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)  # notifyutil registers its observer after it starts
    subprocess.run(["xcrun", "simctl", "spawn", udid, "notifyutil", "-p", "dev.cmux.mobile.termprobe.export"], check=True)
    try:
        waiter.wait(timeout=20)
    except subprocess.TimeoutExpired:
        waiter.kill()
    os.makedirs(outdir, exist_ok=True)
    copied = []
    for f in glob.glob(os.path.join(docs, "*.txt")):
        if os.path.getmtime(f) != before.get(f):
            shutil.copy(f, outdir)
            copied.append(os.path.basename(f))
    return copied


ROW = re.compile(r"#(\d{7}) (.*) crc=([0-9a-f]{8})$")


def crc(path):
    ids, bad, total, rows = [], [], None, []
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = ROW.search(line)
        if m:
            text = line[m.start():m.start(3) - 5]
            ids.append(int(m.group(1)))
            rows.append(line[m.start():])
            if "%08x" % (binascii.crc32(text.encode()) & 0xFFFFFFFF) != m.group(3):
                bad.append(int(m.group(1)))
        t = re.search(r"TOTAL (\d+) ([0-9a-f]{8})", line)
        if t:
            total = (int(t.group(1)), t.group(2))
    dup = len(ids) - len(set(ids))
    lost = sorted(set(range(1, max(ids) + 1)) - set(ids)) if ids else []
    ordered = ids == sorted(ids)
    return {"rows": len(ids), "first": ids[0] if ids else None, "last": ids[-1] if ids else None,
            "lost": len(lost), "lost_ids": lost[:20], "duplicated": dup, "in_order": ordered,
            "crc_bad": len(bad), "crc_bad_ids": bad[:20], "total": total}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "-h"
    if cmd == "echo":
        since = float(sys.argv[sys.argv.index("--since") + 1]) if "--since" in sys.argv else 0.0
        out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
        print(json.dumps(echo(sys.argv[2], sys.argv[3], since, out)))
    elif cmd == "export":
        print(json.dumps(export(sys.argv[2], sys.argv[3], sys.argv[4])))
    elif cmd == "crc":
        print(json.dumps(crc(sys.argv[2])))
    else:
        print(__doc__)
