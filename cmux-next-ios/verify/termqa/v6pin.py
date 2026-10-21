"""VERIFY-round6 bottom-pin pixel check (independent of the app's own `pin:` log).

    python3 v6pin.py PNG_OR_MP4 [--t SECONDS ...] [--card-top PT]

The phone runs a reverse-video bar as its last terminal row (typed on the phone):
    printf '\\e[7m%*s\\e[0m' $COLUMNS ''          (at rest, cursor in the bar row)
    while :; do printf '\\nL\\n\\e[7m%*s\\e[0m' $COLUMNS ''; sleep 0.05; done   (following)
A cell background fills the whole cell height, so the lowest lit bar's bottom edge is
the last row's bottom edge. Reports, in pt (3 px/pt):
  bar_top, bar_bottom, bar_h (should be one row pitch), pitch (from the bar above,
  if any), below: the first pixel row under the bar that is not terminal background,
  gap = below - bar_bottom (0 = flush), clipped = pitch - bar_h (> 0 = overlap).
"""
import argparse
import json
import subprocess
import sys

import numpy as np
from PIL import Image


def analyze(img, card_top_pt=None):
    a = np.asarray(img.convert("RGB")).astype(int)
    h, w, _ = a.shape
    s = w / 402.0
    luma = (a[..., 0] * 299 + a[..., 1] * 587 + a[..., 2] * 114) // 1000
    x0, x1 = int(30 * s), int(370 * s)
    band = luma[:, x0:x1]
    lit_frac = (band > 120).mean(axis=1)
    rows = lit_frac > 0.85
    runs, i = [], 0
    while i < h:
        if rows[i]:
            j = i
            while j < h and rows[j]:
                j += 1
            if j - i >= int(6 * s):
                runs.append((i, j))
            i = j
        else:
            i += 1
    # ignore runs in the keyboard area or the status bar
    runs = [r for r in runs if r[0] > int(60 * s)]
    if not runs:
        return {"error": "no bar"}
    # the lowest bar that is followed by non-lit rows (the composer is not >85% bright)
    top, bot = runs[-1]
    out = {"bar_top": round(top / s, 2), "bar_bottom": round(bot / s, 2), "bar_h": round((bot - top) / s, 2)}
    if len(runs) >= 2:
        out["pitch_from_prev_bar"] = round((runs[-1][0] - runs[-2][0]) / s / 2, 2)  # bars 2 rows apart
    # terminal background: median colour of the 6 px just above the bar (outside text columns)
    bg = np.median(a[max(0, top - int(2 * s)):top, int(388 * s):int(398 * s)].reshape(-1, 3), axis=0)
    # first row under the bar whose mean colour differs from the terminal background
    below = None
    for y in range(bot, min(h, bot + int(60 * s))):
        rowc = a[y, x0:x1].mean(axis=0)
        if np.abs(rowc - bg).max() > 6:
            below = y
            break
    out["bg"] = [int(v) for v in bg]
    if below is not None:
        out["below"] = round(below / s, 2)
        out["below_rgb"] = [int(v) for v in a[below, x0:x1].mean(axis=0)]
        out["gap_px"] = below - bot
        out["gap_pt"] = round((below - bot) / s, 2)
    if card_top_pt is not None:
        out["ax_card_top"] = card_top_pt
        out["ax_gap_pt"] = round(card_top_pt - bot / s, 2)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--t", type=float, nargs="*")
    ap.add_argument("--card-top", type=float)
    a = ap.parse_args()
    if a.src.endswith(".mp4"):
        res = []
        for t in a.t or [0]:
            p = f"/tmp/v6pin-{t:.3f}.png"
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(t), "-i", a.src, "-frames:v", "1", p], check=True)
            r = analyze(Image.open(p), a.card_top)
            r["t"] = t
            res.append(r)
        print(json.dumps(res))
    else:
        print(json.dumps(analyze(Image.open(a.src), a.card_top)))


if __name__ == "__main__":
    main()
