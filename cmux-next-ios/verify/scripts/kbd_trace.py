"""kbd_trace.py <trace.txt> [--frames]

Reads the app's per-frame keyboard trace (`-cmux-mobile-kbd-trace`, one line per
display frame, presentation-layer geometry in window points) and reports,
for each keyboard transition (show, hide, interactive drag):

  gap      keyboard top - composer card bottom while the keyboard is above
           the card's resting place (8 = docked; negative = covered)
  lag      (p_keyboard - p_card) x card travel, p = progress between the
           transition's first and last frame (same curve and timing = 0)
  cgap     card top - transcript bottom (constant = glued to the composer);
           with the empty state, the deviation of its centre from the middle
           of the space between the header and the card (constant = centred)
  jump     largest one-frame change of cgap
  header   navigation bar top across the whole trace (pushed chat)
"""
import sys

rows = []
for line in open(sys.argv[1], errors="ignore"):
    line = line.replace("\x00", "").strip()
    if not line.startswith("t="):
        continue
    d = {}
    for kv in line.split():
        k, _, v = kv.partition("=")
        d[k] = v
    def num(key):
        v = d.get(key, "-")
        return None if v in ("-", "") else float(v)
    nav = d.get("nav", "-,-").split(",")
    rows.append(dict(
        t=float(d["t"]), mode=d.get("mode"), kb=num("kb"), card_top=num("cardTop"), card_bottom=num("cardBottom"),
        dock_top=num("dockTop"), content=num("contentBottom"), empty=num("emptyMid"),
        nav=None if nav[0] == "-" else float(nav[0]), tracking=d.get("tracking") == "1",
    ))
rows = [r for r in rows if r["kb"] is not None and r["card_bottom"] is not None]
if not rows:
    sys.exit("no frames")

# The keyboard's placeholder view reports its final frame for one display
# frame before its animation is attached (the keyboard is not drawn yet; the
# recordings show no keyboard pixels there). Such one-frame spikes are
# dropped and counted.
spikes = 0
clean = [rows[0]]
for i in range(1, len(rows) - 1):
    a, r, b = rows[i - 1], rows[i], rows[i + 1]
    if a["kb"] - r["kb"] > 150 and b["kb"] - r["kb"] > 150:
        spikes += 1
        continue
    clean.append(r)
clean.append(rows[-1])
rows = clean

TOP = 116.0 if rows[0]["mode"] == "pushed" else None


def cgap(r):
    if r["content"] is not None:
        return r["card_top"] - r["content"]
    if r["empty"] is not None:
        top = TOP if TOP is not None else 70.0
        return r["empty"] - (top + r["card_top"]) / 2
    return None


rest_card = max(r["card_bottom"] for r in rows)
segs, cur = [], None
for i in range(1, len(rows)):
    a, b = rows[i - 1], rows[i]
    moving = abs(a["kb"] - b["kb"]) > 0.05
    if moving:
        cur = [i - 1, i] if cur is None else [cur[0], i]
    elif cur is not None and i - cur[1] > 4:
        segs.append(cur)
        cur = None
if cur:
    segs.append(cur)

if "--frames" in sys.argv:
    print("     t      kb  cardTop cardBot  content  empty   gap   cgap  nav  trk")
    for r in rows:
        g = cgap(r)
        print(f"{r['t']:7.3f} {r['kb']:7.2f} {r['card_top']:7.2f} {r['card_bottom']:7.2f} "
              f"{r['content'] if r['content'] is not None else float('nan'):8.2f} {r['empty'] if r['empty'] is not None else float('nan'):6.1f} "
              f"{r['kb'] - r['card_bottom']:6.2f} {g if g is not None else float('nan'):6.2f} {r['nav']} {int(r['tracking'])}")

for a, b in segs:
    s = rows[a:b + 1]
    k0, k1 = s[0]["kb"], s[-1]["kb"]
    c0, c1 = s[0]["card_bottom"], s[-1]["card_bottom"]
    drag = any(r["tracking"] for r in s)
    kind = ("drag-" if drag else "") + ("show" if k1 < k0 - 20 else "hide" if k1 > k0 + 20 else "move")
    lags, gaps = [], []
    for r in s:
        pk = (r["kb"] - k0) / (k1 - k0) if abs(k1 - k0) > 1 else 0
        pc = (r["card_bottom"] - c0) / (c1 - c0) if abs(c1 - c0) > 1 else 0
        if not drag and (0 < pk < 1 or 0 < pc < 1):
            lags.append((pk - pc) * abs(c1 - c0))
        # Only where the keyboard is above the card's resting place does it
        # constrain the card.
        if r["kb"] < rest_card + 8 - 0.5:
            gaps.append(r["kb"] - r["card_bottom"])
    cg = [cgap(r) for r in s if cgap(r) is not None]
    jumps = [abs(cg[i] - cg[i - 1]) for i in range(1, len(cg))]
    print(f"{kind:10s} t={s[0]['t']:.3f}-{s[-1]['t']:.3f}s frames={len(s)} kb {k0:.1f}->{k1:.1f} card {c0:.1f}->{c1:.1f}"
          f" | gap {min(gaps) if gaps else float('nan'):.2f}..{max(gaps) if gaps else float('nan'):.2f}"
          f" | lag {min(lags) if lags else 0:.2f}..{max(lags) if lags else 0:.2f}"
          f" | cgap {min(cg) if cg else float('nan'):.2f}..{max(cg) if cg else float('nan'):.2f}"
          f" | jump {max(jumps) if jumps else 0:.2f}")
print(f"placeholder spikes dropped: {spikes}")
navs = [r["nav"] for r in rows if r["nav"] is not None]
if navs:
    print(f"header top {min(navs):.2f}..{max(navs):.2f} over {len(navs)}/{len(rows)} frames")
