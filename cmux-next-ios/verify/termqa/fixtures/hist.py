#!/usr/bin/env python3
"""usage: hist.py N  print exactly N numbered rows `#%07d <text>` (#0000001..N), then exit."""
import sys
from _rows import row, usage, arg

usage(__doc__, sys.argv)
n = arg(sys.argv, 1, 10000, int)
w = sys.stdout.write
for i in range(1, n + 1):
    w(row(i, stamp=False) + "\n")
sys.stdout.flush()
