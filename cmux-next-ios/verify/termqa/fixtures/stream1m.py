#!/usr/bin/env python3
"""usage: stream1m.py [SECONDS=600] [BITS_PER_S=1000000]  token-bucket paced colored numbered rows `#%07d <send-ms> <text>` with a status line redrawn below."""
import sys
import time
from _rows import row, usage, arg

usage(__doc__, sys.argv)
secs, bps = arg(sys.argv, 1, 600.0), arg(sys.argv, 2, 1e6)
rate = bps / 8.0                            # bytes per second
out = sys.stdout.buffer
start = last = time.monotonic()
tokens, n, sent = 0.0, 0, 0
out.write(b"\n")
while True:
    now = time.monotonic()
    if now - start >= secs:
        break
    tokens = min(tokens + (now - last) * rate, rate * 0.05)   # 50 ms burst cap
    last = now
    chunk = []
    while True:
        line = ("\r\x1b[2K" + row(n + 1, width=70) + "\r\n").encode()
        if tokens < len(line):
            break
        n += 1
        tokens -= len(line)
        chunk.append(line)
    if chunk:
        sent += sum(len(c) for c in chunk)
        out.write(b"".join(chunk) + ("\r\x1b[2K\x1b[7m stream1m \x1b[0m %6.1fs row %d %.0f kbit/s"
                                     % (now - start, n, sent * 8 / max(now - start, 1e-3) / 1000)).encode())
        out.flush()
    time.sleep(0.005)
out.write(("\r\x1b[2KSTREAM1M-END rows=%d bytes=%d\r\n" % (n, sent)).encode())
out.flush()
