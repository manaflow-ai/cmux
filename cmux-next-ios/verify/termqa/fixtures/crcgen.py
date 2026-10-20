#!/usr/bin/env python3
"""usage: crcgen.py N  N rows `#%07d <text> crc=%08x` (CRC32 of `#%07d <text>`), then `TOTAL n crc` (CRC32 of all rows' `#%07d <text>\\n`)."""
import sys
import zlib
from _rows import text, usage, arg

usage(__doc__, sys.argv)
n = arg(sys.argv, 1, 10000, int)
w = sys.stdout.write
total = 0
for i in range(1, n + 1):
    s = "#%07d %s" % (i, text(i))
    total = zlib.crc32((s + "\n").encode(), total)
    w("%s crc=%08x\n" % (s, zlib.crc32(s.encode())))
w("TOTAL %d %08x\n" % (n, total))
sys.stdout.flush()
