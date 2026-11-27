#!/usr/bin/env python3
"""Offset of a remote Mac's wall clock from this one (remote - local, ms),
NTP style over one ssh session: 30 ping-pongs, the minimum-RTT sample wins.
usage: clock-offset.py SSH_HOST"""
import subprocess
import sys
import time

host = sys.argv[1]
remote = "python3 -u -c 'import sys,time\nfor _ in sys.stdin: print(time.time(), flush=True)'"
p = subprocess.Popen(["ssh", host, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
best = None
for _ in range(30):
    t0 = time.time()
    p.stdin.write("x\n")
    p.stdin.flush()
    r = float(p.stdout.readline())
    t1 = time.time()
    sample = (t1 - t0, r - (t0 + t1) / 2)
    if best is None or sample[0] < best[0]:
        best = sample
p.stdin.close()
p.wait()
print(f"offset_ms={best[1] * 1000:.1f} rtt_ms={best[0] * 1000:.1f}")
