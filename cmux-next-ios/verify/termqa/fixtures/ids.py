#!/usr/bin/env python3
"""usage: ids.py [N=2000000]  like `yes`, but each row is `#%07d y` (fast, plain, no colour), then IDS-END."""
import sys
from _rows import usage, arg

usage(__doc__, sys.argv)
n = arg(sys.argv, 1, 2000000, int)
out = sys.stdout.buffer
B = 50000
for s in range(1, n + 1, B):
    out.write("".join("#%07d y\n" % i for i in range(s, min(s + B, n + 1))).encode())
out.write(b"IDS-END %d\n" % n)
out.flush()
