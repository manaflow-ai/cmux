#!/usr/bin/env python3
"""Glass-to-glass latency from simulator stills of a streamed browser tab.
Each still shows the Mac page's clock ("mac MM:SS.mmm", rendered by the Mac's
browser and streamed) and the phone's own clock in the overlay ("phone
MM:SS.mmm"). latency = phone - mac - offset, where offset = Mac clock minus
this Mac's clock (clock-offset.py). Input: ocr-frames.swift output on stdin.
usage: swift ocr-frames.swift stills/*.png | browser-latency.py OFFSET_MS"""
import re
import statistics
import sys

offset = float(sys.argv[1])
clock = r"(\d{2}):(\d{2})[.,:](\d{3})"
values = []
for line in sys.stdin:
    mac = re.search(r"mac\s+" + clock, line)
    phone = re.search(r"phone\s+" + clock, line)
    if not mac or not phone:
        continue
    ms = lambda m: (int(m.group(1)) * 60 + int(m.group(2))) * 1000 + int(m.group(3))
    d = (ms(phone) - ms(mac) - offset) % 3_600_000
    if d > 1_800_000:
        d -= 3_600_000
    if -100 < d < 5000:
        values.append(d)
        print(f"{line.split(chr(9))[0]}\t{d:.0f} ms")
if values:
    values.sort()
    print(f"n={len(values)} min={values[0]:.0f} p50={statistics.median(values):.0f} "
          f"p90={values[int(len(values) * 0.9) - 1 if len(values) > 1 else 0]:.0f} max={values[-1]:.0f} ms")
