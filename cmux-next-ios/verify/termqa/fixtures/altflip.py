#!/usr/bin/env python3
"""usage: altflip.py [SECONDS=60] [HZ=20]  enter/leave the alternate screen HZ times/s drawing a numbered frame `#%07d`, end on the main screen with `ALTFLIP-END cycles=N`."""
import sys
import time
from _rows import usage, arg

usage(__doc__, sys.argv)
secs, hz = arg(sys.argv, 1, 60.0), arg(sys.argv, 2, 20.0)
w = sys.stdout.write
start = time.monotonic()
n = 0
while time.monotonic() - start < secs:
    n += 1
    w("\x1b[?1049h\x1b[H\x1b[2J")
    for r in range(1, 21):
        w("\x1b[%d;1H#%07d alt frame %d row %d" % (r, n * 100 + r, n, r))
    sys.stdout.flush()
    time.sleep(0.5 / hz)
    w("\x1b[?1049l")
    sys.stdout.flush()
    time.sleep(max(0.0, start + n / hz - time.monotonic()))
w("ALTFLIP-END cycles=%d\n" % n)
sys.stdout.flush()
