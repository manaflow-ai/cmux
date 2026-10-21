#!/usr/bin/env python3
"""usage: line1m.py [BYTES=1048576]  one BYTES-long line with no newline, then a newline and `#0000001 LINE1M-END bytes=N`."""
import sys
from _rows import usage, arg

usage(__doc__, sys.argv)
n = arg(sys.argv, 1, 1 << 20, int)
pat = b"0123456789abcdefghijklmnopqrstuvwxyz"
data = (pat * (n // len(pat) + 1))[:n]
out = sys.stdout.buffer
out.write(data)
out.write(b"\n#0000001 LINE1M-END bytes=%d\n" % n)
out.flush()
