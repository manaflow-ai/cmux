"""kbd_pixels.py <frames-dir> [--tab] [--light]

Per recorded frame (dark appearance, full-resolution frames from frames.sh
with scale-width 1206 or any width; values in pt), for verify/keyboard.md:

  kb       keyboard top: the keyboard is present when the column at x = 4 pt
           is lit 50 pt above the bottom; its top is where the centre column
           (x = 201 pt) turns black scanning up. The screen bottom otherwise.
  cb, ct   composer bottom / top: above the keyboard (or above the TabsKit
           toolbar with --tab, or the screen bottom), skip black, then the
           lit run in the centre column is the composer (the empty middle of
           the glass card, never text).
  content  bottom of the transcript's lowest lit row above the composer
           (x 20-380 pt, a pixel brighter than 40 of 255).
  header   first row of the navigation title (pushed chat: x 110-290 pt,
           y 50-120 pt, 20 or more pixels brighter than 200), or the status
           bar clock with --tab (TabsKit draws no header).

Then, over the frames where the keyboard or the composer moves:
  gap      kb - cb (the composer's clearance above the keyboard; negative =
           the keyboard covers it)
  lag      (p_kb - p_composer) x composer travel, p = progress from the first
           to the last frame of the transition (same curve = 0)
  cgap     ct - content (constant when the content is glued to the composer)
  jump     per-frame change of content minus change of ct (content moving
           separately from the composer)
  header   spread of the header row across the whole recording
"""
import glob, os, sys
import numpy as np
from PIL import Image

TAB = "--tab" in sys.argv
frames = sorted(glob.glob(os.path.join(sys.argv[1], "*.png")))
rows = []
for path in frames:
    im = np.asarray(Image.open(path).convert("RGB")).astype(int)
    h, w, _ = im.shape
    pt = w / 402
    lum = im.mean(axis=2)
    P = lambda v: int(round(v * pt))
    cx = P(201)
    # keyboard
    probe = h - P(50)
    if lum[probe, P(4)] > 12:
        y = probe
        while y > 0 and lum[y, cx] > 12:
            y -= 1
        kb = y + 1
    else:
        kb = h
    # composer bottom: from just above the keyboard (or the bottom), skip lit
    # (keyboard, toolbar), skip black, then the composer.
    y = min(kb, h) - 1
    while y > 0 and lum[y, cx] > 12:
        y -= 1
    while y > 0 and lum[y, cx] <= 12:
        y -= 1
    cb = y + 1
    # TabsKit's toolbar sits below the composer with the keyboard down: when
    # the first lit run is the toolbar (short, near the bottom), skip it too.
    if TAB and kb >= h and cb > h - P(120):
        while y > 0 and lum[y, cx] > 12:
            y -= 1
        while y > 0 and lum[y, cx] <= 12:
            y -= 1
        cb = y + 1
    y = cb - P(2)
    while y > 0 and lum[y, cx] > 12:
        y -= 1
    ct = y + 1
    # content bottom
    band = lum[:, P(20):P(380)]
    y = ct - P(3)
    while y > P(60) and band[y].max() <= 40:
        y -= 1
    content = y + 1
    # header
    if TAB:
        hb = lum[P(18):P(48), P(40):P(120)]
        lit = np.where((hb > 200).sum(axis=1) >= 5)[0]
        header = (lit[0] + P(18)) / pt if len(lit) else None
    else:
        hb = lum[P(50):P(120), P(110):P(290)]
        lit = np.where((hb > 200).sum(axis=1) >= 20)[0]
        header = (lit[0] + P(50)) / pt if len(lit) else None
    ms = int(os.path.basename(path).split("_")[-1][:-4])
    rows.append(dict(ms=ms, kb=kb / pt, cb=cb / pt, ct=ct / pt, content=content / pt, header=header))

print("    ms      kb      cb      ct  content   gap   cgap  header")
for r in rows:
    print(f"{r['ms']:6d} {r['kb']:7.1f} {r['cb']:7.1f} {r['ct']:7.1f} {r['content']:8.1f} {r['kb'] - r['cb']:6.1f} {r['ct'] - r['content']:6.1f} {r['header'] if r['header'] is None else round(r['header'], 1)}")

# transitions: runs of frames where kb or cb moves by more than 0.4 pt
def moving(a, b):
    return abs(a["kb"] - b["kb"]) > 0.4 or abs(a["cb"] - b["cb"]) > 0.4

segs, cur = [], None
for i in range(1, len(rows)):
    if moving(rows[i - 1], rows[i]):
        if cur is None:
            cur = [i - 1, i]
        else:
            cur[1] = i
    elif cur is not None and i - cur[1] > 3:
        segs.append(cur)
        cur = None
if cur:
    segs.append(cur)

headers = [r["header"] for r in rows if r["header"] is not None]
print()
for a, b in segs:
    s = rows[a:b + 1]
    k0, k1, c0, c1 = s[0]["kb"], s[-1]["kb"], s[0]["cb"], s[-1]["cb"]
    kind = "show" if k1 < k0 - 20 else ("hide" if k1 > k0 + 20 else "other")
    lags = []
    for r in s:
        pk = (r["kb"] - k0) / (k1 - k0) if abs(k1 - k0) > 1 else 0
        pc = (r["cb"] - c0) / (c1 - c0) if abs(c1 - c0) > 1 else 0
        if 0 < pk < 1 or 0 < pc < 1:
            lags.append((pk - pc) * abs(c1 - c0))
    gaps = [r["kb"] - r["cb"] for r in s if r["kb"] < 873]
    cgaps = [r["ct"] - r["content"] for r in s]
    jumps = [(s[i]["content"] - s[i - 1]["content"]) - (s[i]["ct"] - s[i - 1]["ct"]) for i in range(1, len(s))]
    print(f"{kind:5s} {s[0]['ms']}-{s[-1]['ms']} ms frames={len(s)} kb {k0:.1f}->{k1:.1f} composer {c0:.1f}->{c1:.1f}"
          f" | gap min={min(gaps) if gaps else float('nan'):.1f} max={max(gaps) if gaps else float('nan'):.1f}"
          f" | lag {min(lags) if lags else 0:.2f}..{max(lags) if lags else 0:.2f} pt"
          f" | cgap {min(cgaps):.1f}..{max(cgaps):.1f} | jump {min(jumps) if jumps else 0:.2f}..{max(jumps) if jumps else 0:.2f} pt")
if headers:
    print(f"header row: {min(headers):.1f}..{max(headers):.1f} pt over {len(headers)} of {len(rows)} frames")
