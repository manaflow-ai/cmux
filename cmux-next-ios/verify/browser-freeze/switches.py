#!/usr/bin/env python3
"""Per-switch recovery of a brfz_soak.py run: for each host `media lane switched route`
line, the seconds to the phone's next `browser <tab>: N fps` os_log line, the host's
keyframe-request rate over the following 10 s, and the phone's diagnostic lines (gate,
viewer not reading, other tab's frames, receiver gave up a gap, Swift skipped frames) in
the 15 s after it. Also the run's media session up/down lines and any "Reconnecting".

    python3 switches.py RUN_DIR [--json]
"""
import datetime
import json
import os
import re
import sys

d = sys.argv[1]
UTC = datetime.timezone.utc


def iso(ts):
    return datetime.datetime.strptime(ts[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=UTC).timestamp()


def hhmmss(t):
    return datetime.datetime.fromtimestamp(t, UTC).strftime("%H:%M:%S.%f")[:-3]


host = []
for line in open(os.path.join(d, "hostd-live.log"), errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z\s+\w+ \S+: (.*)", line)
    if m:
        host.append((iso(m.group(1)), m.group(2)))
# os_log compact lines carry local time; the stream ran on the mini (UTC-7 on 2026-10-24).
fps = []
oslog_other = []
offset = None
for line in open(os.path.join(d, "oslog-stream.log"), errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
    if not m:
        continue
    local = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
    if offset is None:
        offset = -7 * 3600
    t = local.replace(tzinfo=UTC).timestamp() - offset
    f = re.search(r"browser (\S+): (\d+) fps .* via (\S+)", line)
    if f:
        fps.append((t, f.group(1), int(f.group(2)), f.group(3)))
    elif re.search(r"skipped \d+ frames|decode failed|Reconnecting|closed:|stalled|reopen", line):
        oslog_other.append((t, line.strip()[-220:]))
phone = []
for f in sorted(os.listdir(d)):
    if f.startswith("phone-stderr.log."):
        for line in open(os.path.join(d, f), errors="replace"):
            m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z\s+\w+ \S+: (.*)", line)
            if m and re.search(r"media gate|not reading|another tab|gave a gap up|media session|switched route|keyframe", m.group(2)):
                phone.append((iso(m.group(1)), m.group(2)[:400]))


def kf_rate(t0, t1):
    pts = []
    for t, body in host:
        if t0 <= t <= t1 and body.startswith("browser: media lane"):
            k = re.search(r"packets=(\d+) .*keyframe_requests=(\d+)", body)
            if k:
                pts.append((t, int(k.group(1)), int(k.group(2))))
    # the lane with the most packets is the shown tab's
    if len(pts) < 2:
        return None
    best = {}
    for t, pk, kf in pts:
        lane = min(best, key=lambda x: abs(best[x][-1][1] - pk), default=None)
        if lane is None or pk < best[lane][-1][1]:
            best[len(best)] = [(t, pk, kf)]
        else:
            best[lane].append((t, pk, kf))
    rates = [(s[-1][2] - s[0][2]) / (s[-1][0] - s[0][0]) for s in best.values() if len(s) > 1 and s[-1][0] > s[0][0]]
    return round(max(rates), 2) if rates else None


rows = []
for t, body in host:
    if "media lane switched route" not in body:
        continue
    frm = (re.search(r'from="([^"]+)"', body) or [0, "?"])[1]
    to = (re.search(r'to="([^"]+)"', body) or [0, "?"])[1]
    nxt = next((x for x in fps if x[0] >= t), None)
    gap = round(nxt[0] - t, 2) if nxt else None
    diag = [f"{hhmmss(pt)} {b}" for pt, b in phone if t - 1 <= pt <= t + 15]
    diag += [f"{hhmmss(pt)} {b}" for pt, b in oslog_other if t - 1 <= pt <= t + 15]
    rows.append({"t": hhmmss(t), "from": frm, "to": to, "next_frame_s": gap,
                 "next_fps": f"{nxt[2]} via {nxt[3]} ({nxt[1]})" if nxt else None,
                 "kf_per_s_10s": kf_rate(t, t + 12), "phone_lines": diag[:25]})
sessions = [f"{hhmmss(t)} {b[:150]}" for t, b in host if re.match(r"media session (up|down|failed)", b)]
reconnect = [f"{hhmmss(t)} {b}" for t, b in oslog_other if "Reconnect" in b]
if "--json" in sys.argv:
    print(json.dumps({"switches": rows, "sessions": sessions, "reconnecting": reconnect}, indent=2))
    sys.exit()
print("| # | switch (UTC) | from -> to | next phone frame s | that line | PLIs/s next 12 s | phone diag lines |")
print("| --- | --- | --- | --- | --- | --- | --- |")
for i, r in enumerate(rows, 1):
    print(f"| {i} | {r['t']} | {r['from']} -> {r['to']} | {r['next_frame_s']} | {r['next_fps']} | {r['kf_per_s_10s']} | {len(r['phone_lines'])} |")
print(f"\nmedia sessions: {len(sessions)} lines; reconnecting lines: {len(reconnect)}")
for r in rows:
    if r["next_frame_s"] is None or r["next_frame_s"] > 5:
        print(f"\n## switch {r['t']} ({r['from']} -> {r['to']}): next frame {r['next_frame_s']}")
        for l in r["phone_lines"]:
            print("   ", l)
