"""track_video.py <video.mp4> <out.csv>

Streams every recorded frame of a simulator recording (variable frame rate,
full resolution, left 320 px only) and measures per frame, in pt:
  kb     visible keyboard top (column at 101 pt, scanning up from the bottom
         through keyboard pixels; 874 = no keyboard on screen)
  stack  bottom edge of the bottom stack (column at 67 pt, first non-black
         pixel above the keyboard)
  tui    bottom of htop's cyan footer row above the stack (column at 20 pt)
Then finds each keyboard transition (a run of frames where kb moves, framed by
two still frames) and reports, per transition, how the stack tracks the
keyboard: p = progress of each from its start to its end position; lag_pt =
(p_kb - p_stack) * stack travel. Frames where the keyboard is not drawn yet
(kb at the screen bottom while the stack already moves) are counted apart.
"""
import json, os, subprocess, sys
import numpy as np
# Embedded terminal (a workspace tab): STACK_FLOOR=<pt> starts the stack scan
# above TabsKit's toolbar, which is not black.
FLOOR = float(os.environ.get("STACK_FLOOR", "10000"))


def footer_bottom(rows, pt):
    """Bottom of the lowest run of cyan rows at least 12 pt tall (a footer
    cell is 16 pt; thin cyan in the glass refraction below it is ignored)."""
    if len(rows) == 0:
        return None
    runs, start = [], rows[0]
    for a, b in zip(rows, rows[1:]):
        if b != a + 1:
            runs.append((start, a)); start = b
    runs.append((start, rows[-1]))
    tall = [r for r in runs if r[1] - r[0] + 1 >= 12 * pt]
    return int(tall[-1][1]) + 1 if tall else None

video, out = sys.argv[1], sys.argv[2]
probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                        "-of", "json", video], capture_output=True, text=True, check=True)
times = [float(f["pts_time"]) for f in json.loads(probe.stdout)["frames"]]
W, H, CW = 1206, 2622, 320
proc = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "fatal", "-i", video, "-vf", f"crop={CW}:{H}:0:0", "-fps_mode", "passthrough",
                         "-enc_time_base", "1/1000", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
pt = 3.0
rows = []
size = CW * H * 3
i = 0
while True:
    buf = proc.stdout.read(size)
    if len(buf) < size:
        break
    im = np.frombuffer(buf, np.uint8).reshape(H, CW, 3).astype(np.int16)
    lum = im.mean(axis=2)
    x = int(101 * pt)
    y = H - 4
    if lum[y, x] < 6:
        kb = H
    else:
        while y > 3 and not (lum[y, x] < 6 and lum[y - 1, x] < 6 and lum[y - 2, x] < 6):
            y -= 1
        kb = y + 1
    xs = int(67 * pt)
    y = min(kb, H - int(40 * pt), int(FLOOR * pt)) - 1
    while y > 0 and lum[y, xs] < 6:
        y -= 1
    stack = y + 1
    band = im[:stack, int(17 * pt):int(40 * pt)]
    is_cyan = (band[:, :, 1] > 150) & (band[:, :, 2] > 150) & (band[:, :, 0] < 170)
    cyan = np.where(is_cyan.mean(axis=1) > 0.3)[0]
    fb = footer_bottom(cyan, pt)
    tui = fb / pt if fb else -1
    t = times[i] if i < len(times) else -1
    rows.append((t, kb / pt, stack / pt, tui))
    i += 1
proc.wait()
with open(out, "w") as f:
    f.write("t,kb,stack,tui\n")
    for r in rows:
        f.write("%.4f,%.2f,%.2f,%.2f\n" % r)

# Transitions: maximal runs where kb differs from the previous frame by > 0.5 pt.
moving = [abs(rows[k][1] - rows[k - 1][1]) > 0.5 or abs(rows[k][2] - rows[k - 1][2]) > 0.5 for k in range(1, len(rows))]
segments, k = [], 0
while k < len(moving):
    if moving[k]:
        start = k
        while k < len(moving) and (moving[k] or any(moving[k:k + 4])):
            k += 1
        segments.append((start, k))
    k += 1
print(f"frames={len(rows)}")
for start, end in segments:
    a, b = rows[max(start - 1, 0)], rows[min(end + 3, len(rows) - 1)]
    kb0, kb1, st0, st1 = a[1], b[1], a[2], b[2]
    if abs(kb1 - kb0) < 100 or abs(st1 - st0) < 100 or not (500 < min(kb0, kb1) < 800):
        continue  # not a keyboard show or hide (scrolling content, sheets)
    lags, hidden, tgaps = [], 0, []
    for r in rows[start:end + 1]:
        pk = (r[1] - kb0) / (kb1 - kb0)
        ps = (r[2] - st0) / (st1 - st0)
        if r[1] >= 872:
            # No keyboard pixels on screen: not drawn yet (show) or gone (hide).
            if 0.01 < ps < 0.99:
                hidden += 1
            continue
        lags.append((pk - ps) * abs(st1 - st0))
        if r[3] > 0 and 40 < r[2] - r[3] < 160:
            tgaps.append(r[2] - r[3])
    kind = "show" if kb1 < kb0 else "hide"
    tg = f" tui_gap {min(tgaps):.1f}..{max(tgaps):.1f}" if tgaps and min(tgaps) > 0 else ""
    print(f"{kind} t={a[0]:7.3f}-{b[0]:7.3f}s kb {kb0:.0f}->{kb1:.0f} stack {st0:.0f}->{st1:.0f} frames={end - start + 1} "
          f"keyboard-not-drawn={hidden} lag_pt {min(lags):+.2f}..{max(lags):+.2f}{tg}")
