#!/usr/bin/env python3
"""usage: stream20.py [SECONDS=300] [RATE=20]  numbered rows `#%07d <send-ms> <text>` at RATE/s with a 2-line status area redrawn below (Codex-like live area)."""
import sys
import time
from _rows import row, usage, arg

usage(__doc__, sys.argv)
secs, rate = arg(sys.argv, 1, 300.0), arg(sys.argv, 2, 20.0)
w = sys.stdout.write
start = time.monotonic()
n = 0
w("\n")                                     # the live area: 2 lines, cursor on its last
while True:
    now = time.monotonic()
    if now - start >= secs:
        break
    n += 1
    # Up to the live area's first line, erase it, print the row, redraw the live area.
    w("\x1b[1A\r\x1b[J" + row(n) + "\r\n")
    w("\x1b[2m• working %5.1fs · row %d · %d/s\x1b[0m\r\n\x1b[7m status \x1b[0m %s"
      % (now - start, n, int(rate), time.strftime("%H:%M:%S")))
    sys.stdout.flush()
    time.sleep(max(0.0, start + n / rate - time.monotonic()))
w("\x1b[1A\r\x1b[J" + "STREAM20-END rows=%d\r\n" % n)
sys.stdout.flush()
