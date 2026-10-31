"""keyboard_track.py <frames-dir> [--tui]

Measures, per recorded frame (any width; values in pt), during one keyboard
show or hide:
  kb     visible keyboard top: scan up a column (clear of the home indicator)
         from the screen bottom through keyboard pixels; the screen bottom
         when no keyboard is on screen
  stack  bottom edge of the bottom stack (key bar, or the composer while the
         key bar is collapsed): first non-black pixel above the keyboard
  tui    (--tui) bottom of htop's cyan footer, the last TUI row
Then compares progress: p = (v - v_first) / (v_last - v_first) for the
keyboard and the stack. Same curve and timing means p_kb == p_stack on every
frame; `lag_pt` is (p_kb - p_stack) times the stack's travel (positive: the
stack is behind the keyboard). `tui_gap` = stack - tui bottom; `tui_row_vs_stack_err_pt` is the TUI's
last row against its position predicted from the stack's progress (0 = the
TUI frame moves with the composer on the same curve).
"""
import glob, os, sys
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
from PIL import Image

frames = sorted(glob.glob(os.path.join(sys.argv[1], "*.png")))
tui = "--tui" in sys.argv
data = []
for path in frames:
    im = np.asarray(Image.open(path).convert("RGB")).astype(int)
    h, w, _ = im.shape
    pt = w / 402
    lum = im.mean(axis=2)
    x = int(w / 2 - 100 * pt)
    y = h - 4
    if lum[y, x] < 6:
        kb = h
    else:
        while y > 3 and not (lum[y, x] < 6 and lum[y - 1, x] < 6 and lum[y - 2, x] < 6):
            y -= 1
        kb = y + 1
    xs = int(67 * pt)
    y = min(kb, h - int(40 * pt), int(FLOOR * pt)) - 1
    while y > 0 and lum[y, xs] < 6:
        y -= 1
    stack = y + 1
    footer = None
    if tui:
        band = im[:stack, int(17 * pt):int(40 * pt)]
        is_cyan = (band[:, :, 1] > 150) & (band[:, :, 2] > 150) & (band[:, :, 0] < 170)
        cyan = np.where(is_cyan.mean(axis=1) > 0.3)[0]
        footer = footer_bottom(cyan, pt)
    data.append((int(os.path.basename(path)[2:-4]), kb / pt, stack / pt, footer / pt if footer else None))

kb0, kb1 = data[0][1], data[-1][1]
st0, st1 = data[0][2], data[-1][2]
print(f"keyboard {kb0:.1f} -> {kb1:.1f} pt, stack {st0:.1f} -> {st1:.1f} pt")
print("   ms    kb_pt  stack_pt  p_kb   p_stack  lag_pt  tui_gap_pt")
ft0, ft1 = data[0][3], data[-1][3]
tui_errs = []
lags, gaps, not_drawn = [], [], 0
# Embedded: while the keyboard's top is behind TabsKit's toolbar (glass, not
# black) the column scan stops at the toolbar instead; those frames are
# counted as occluded, not measured.
occluded = 0
for ms, kb, st, ft in data:
    pk = (kb - kb0) / (kb1 - kb0) if kb1 != kb0 else 0
    ps = (st - st0) / (st1 - st0) if st1 != st0 else 0
    lag = (pk - ps) * abs(st1 - st0)
    moving = 0.0 < pk < 1.0 or 0.0 < ps < 1.0
    if kb >= 872 and 0.01 < ps < 0.99:
        # No keyboard pixels yet: the system has not drawn the keyboard in
        # this frame (it appears a few ms after its animation starts).
        not_drawn += 1
        moving = False
    if moving and FLOOR < 10000 and FLOOR - 5 < kb < FLOOR + 60:
        occluded += 1
        moving = False
    if moving: lags.append(lag)
    g = st - ft if ft else None
    if ft and ft0 and ft1 and st1 != st0:
        # The TUI's last row should progress exactly like the stack (same
        # layout pass, same curve): predicted from the stack's progress.
        tui_errs.append(ft - (ft0 + (ft1 - ft0) * ps))
    if g is not None: gaps.append(g)
    print(f"{ms:6d} {kb:7.1f} {st:8.1f} {pk:6.3f} {ps:7.3f} {lag:7.2f} {'' if g is None else f'{g:8.1f}'}")
if lags:
    print(f"moving frames={len(lags)} keyboard-not-drawn={not_drawn} toolbar-occluded={occluded} lag_pt min={min(lags):.2f} max={max(lags):.2f}")
if gaps:
    print(f"tui_gap_pt min={min(gaps):.1f} max={max(gaps):.1f}")
if tui_errs:
    print(f"tui_row_vs_stack_err_pt min={min(tui_errs):.2f} max={max(tui_errs):.2f}")
