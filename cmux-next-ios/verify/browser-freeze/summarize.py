#!/usr/bin/env python3
"""Per-minute table of a brfz_soak.py run folder (also for a run stopped before its own
summary): decoded frames (30 per phone fps line), max fps, carriers, host keyframe
requests (per-lane deltas), inputs, no-response inputs and the median input round trip.

    python3 summarize.py RUN_DIR
"""
import datetime
import json
import os
import re
import sys

d = sys.argv[1]
acts = [json.loads(l) for l in open(os.path.join(d, "actions.jsonl"))]
t0 = acts[0]["t"]
rows = {}


def row(t):
    return rows.setdefault(int((t - t0) // 60), {"frames": 0, "fps": [], "car": set(), "kf": 0, "in": 0, "none": 0, "rtt": []})


for line in open(os.path.join(d, "oslog-stream.log"), errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).*browser (\S+): (\d+) fps .* via (\S+)", line)
    if m:
        t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
        r = row(t)
        r["frames"] += 30
        r["fps"].append(int(m.group(3)))
        r["car"].add(m.group(4))
# keyframe requests: each "media lane" report belongs to one lane; follow lanes by packets continuity
lanes = []
for line in open(os.path.join(d, "hostd-live.log"), errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z.*browser: media lane .*packets=(\d+) .*keyframe_requests=(\d+)", line)
    if not m:
        continue
    t = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp()
    if t < t0:
        continue
    pk, kf = int(m.group(2)), int(m.group(3))
    best = None
    for lane in lanes:
        if pk >= lane["pk"] and t - lane["t"] < 12 and (best is None or pk - lane["pk"] < pk - best["pk"]):
            best = lane
    if best is None:
        lanes.append({"pk": pk, "kf": kf, "t": t})
        continue
    row(t)["kf"] += max(0, kf - best["kf"])
    best.update(pk=pk, kf=kf, t=t)
for a in acts:
    if a.get("act") in ("scroll-down", "scroll-up", "tap", "back", "forward", "search", "long-scroll"):
        r = row(a["t"])
        r["in"] += 1
        if a.get("rtt") is None:
            r["none"] += 1
        else:
            r["rtt"].append(a["rtt"])
print("| min | UTC | decoded frames | max fps | via | PLIs (host) | inputs | no response | median RTT s |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for k in sorted(rows):
    r = rows[k]
    rt = sorted(r["rtt"])
    utc = datetime.datetime.fromtimestamp(t0 + k * 60, datetime.timezone.utc).strftime("%H:%M")
    print(f"| {k} | {utc} | {r['frames']} | {max(r['fps'], default=0)} | {','.join(sorted(r['car'])) or '-'} | {r['kf']} | "
          f"{r['in']} | {r['none']} | {rt[len(rt)//2] if rt else '-'} |")
