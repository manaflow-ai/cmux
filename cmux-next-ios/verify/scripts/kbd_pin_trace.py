#!/usr/bin/env python3
"""Reads Documents/kbd-pin-trace.txt (-cmux-mobile-kbd-pin-trace) and reports,
frame by frame, how the focused composer field follows the keyboard
(verify/keyboard-pin.md).

Per frame: kb is the keyboard's top as drawn (window points), fb the field's
bottom. Docked means a full-width keyboard whose top is above the field's
resting bottom plus the docked gap, so the field must ride it.

  gap      kb - fb once the keyboard is still (the docked gap).
  lag      per keyboard transition (show, hide, a drag's settle): the
           composer's progress minus the keyboard's, times the composer's
           travel; 0 = the composer moves on the keyboard's own curve.
  overlap  frames where a docked keyboard covers the field (fb > kb).
  jump     the field moved more than 1 pt in a frame while the keyboard did
           not move at all (a composer that moves on its own timeline).
  drift    while the transcript follows the newest content and no finger is
           down, the content's bottom moved differently from the field's.
  rest     the field's bottom with no keyboard; it should not change.

During an interactive dismissal UIKit does not move the keyboard's
placeholder (kb stays where the drag began, iOS 26 and 27), while the system
keyboard layout guide (kg) follows the finger-driven keyboard frame by frame.
On frames where kb has not moved but kg reports a docked keyboard elsewhere,
the keyboard's top is taken from kg (in window points, as kg is).

usage: kbd_pin_trace.py TRACE [--json] [--frames]
"""
import json
import re
import statistics
import sys

PAIR = re.compile(r"(\w+)=(\S+)")


def parse(path):
    frames, events = [], []
    for line in open(path, encoding="utf-8", errors="replace"):
        kv = dict(PAIR.findall(line))
        if "t" not in kv:
            continue
        t = float(kv["t"])
        if "ev" in kv:
            events.append({"t": t, "ev": kv["ev"], "end": kv.get("end"), "dur": float(kv.get("dur", 0))})
            continue
        f = {"t": t}
        w, h = (float(x) for x in kv.get("win", "0x0").split("x"))
        f["winw"], f["winh"] = w, h
        f["orient"] = int(kv.get("orient", 0))
        f["hw"] = kv.get("hw") == "1"
        f["kb"] = None if kv.get("kb", "-") == "-" else float(kv["kb"])
        f["kbw"] = float(kv["kbw"]) if "kbw" in kv else 0.0
        f["kbh"] = float(kv["kbh"]) if "kbh" in kv else 0.0
        f["field"] = kv.get("field", "-")
        for k in ("fy", "fb", "cb", "off", "inb", "kg", "kgh", "dg"):
            f[k] = float(kv[k]) if k in kv else None
        f["fr"] = kv.get("fr") == "1"
        f["trk"] = kv.get("trk") == "1"
        frames.append(f)
    # The keyboard during interactive dismissals: see the docstring.
    # The placeholder reports its final frame for one frame before its show
    # animation attaches (verify/keyboard.md, "placeholder spikes"); drop it.
    for i in range(1, len(frames) - 1):
        a, b, c = frames[i - 1], frames[i], frames[i + 1]
        if a["kb"] is None and b["kb"] is not None and c["kb"] is not None and c["kb"] > b["kb"] + 50:
            b["kb"] = None
            b["spike"] = True
    # One frame where the field reads far from both neighbours, which agree:
    # its ancestors' presentation layers mid-hand-off as it becomes first
    # responder (the recordings show no such frame); drop it.
    for i in range(1, len(frames) - 1):
        a, b, c = frames[i - 1], frames[i], frames[i + 1]
        if None not in (a["fb"], b["fb"], c["fb"]) and abs(a["fb"] - c["fb"]) < 5 and abs(b["fb"] - a["fb"]) > 100:
            b["fb"] = None
            b["outlier"] = True
    rest_kg = [f["kg"] for f in frames if f["kb"] is None and f["kg"] is not None]
    kg_rest = statistics.median(rest_kg) if rest_kg else None
    raw = [f["kb"] for f in frames]
    for i in range(1, len(frames)):
        b = frames[i]
        if (raw[i] is not None and raw[i - 1] is not None and abs(raw[i] - raw[i - 1]) < 0.01
                and b["kg"] is not None and (b["kgh"] or 0) > 0.5 and abs(b["kg"] - b["kb"]) > 0.5
                and (kg_rest is None or b["kg"] < kg_rest - 0.5)):
            b["kb"] = b["kg"]
            b["kbh"] = b["kgh"]
            b["kb_from"] = "kg"
    # In iOS 27's stalled state neither the placeholder nor kg moves during a
    # drag; the composer's dock guide (dg, placed from the finger the way
    # UIKit places the keyboard) is the only live reading. Pixel measurements
    # of the recordings (kbtop.py) agree with it; use it on those frames.
    for i in range(1, len(frames)):
        b = frames[i]
        ahead = raw[i:i + 4]
        if (raw[i] is not None and raw[i - 1] is not None and abs(raw[i] - raw[i - 1]) < 0.01
                and len(ahead) == 4 and all(v is not None and abs(v - raw[i]) < 0.01 for v in ahead)
                and b.get("kb_from") is None and b["dg"] is not None and b["dg"] > b["kb"] + 0.5
                and b["kg"] is not None and (b["kgh"] or 0) < 0.5):
            b["kb"] = b["dg"]
            b["kb_from"] = "dg"
    return frames, events


def analyze(frames):
    out = {"frames": len(frames)}
    out["field_outliers_dropped"] = sum(1 for f in frames if f.get("outlier"))
    usable = [f for f in frames if f["fb"] is not None]
    if not usable:
        out["error"] = "no composer field in the trace"
        return out
    # Each window size is its own geometry (rotation, iPad resize).
    by_size = {}
    for f in usable:
        by_size.setdefault((round(f["winw"]), round(f["winh"])), []).append(f)
    out["sizes"] = {}
    for size, fs in by_size.items():
        out["sizes"][f"{size[0]}x{size[1]}"] = analyze_size(fs)
    return out


def docked(f):
    return f["kb"] is not None and f["kbw"] >= f["winw"] - 1 and f["kb"] < f["winh"] - 1


def kb_top(f):
    return f["kb"] if f["kb"] is not None else f["winh"]


def transitions(fs):
    """Runs of frames where the keyboard moves on its own (no finger down),
    with one still frame on each side."""
    runs, cur = [], None
    for i in range(1, len(fs)):
        moving = abs(kb_top(fs[i]) - kb_top(fs[i - 1])) > 0.01 and not fs[i]["trk"]
        if moving:
            cur = cur or [i - 1]
            cur.append(i)
        elif cur:
            cur.append(i)
            runs.append(cur)
            cur = None
    return runs


def analyze_size(fs):
    r = {"frames": len(fs)}
    rest = [f["fb"] for f in fs if f["kb"] is None or not docked(f)]
    rest_settled = [b for a, b in zip(rest, rest[1:]) if abs(a - b) < 0.01]
    r["rest_fb"] = statistics.median(rest_settled) if rest_settled else (statistics.median(rest) if rest else None)
    # Docked gap: frames where the keyboard is still, docked, and the field is too.
    still = []
    for a, b in zip(fs, fs[1:]):
        if docked(a) and docked(b) and abs(a["kb"] - b["kb"]) < 0.01 and abs(a["fb"] - b["fb"]) < 0.01 and b["fr"]:
            still.append(b["kb"] - b["fb"])
    r["docked_gap"] = statistics.median(still) if still else None
    rest_fb = r["rest_fb"]
    overlaps, jumps, drifts = [], [], []
    for a, b in zip(fs, fs[1:]):
        if docked(b) and b["fb"] > b["kb"] + 0.5:
            overlaps.append((round(b["t"], 3), round(b["fb"] - b["kb"], 2)))
        dfb = b["fb"] - a["fb"]
        if abs(kb_top(b) - kb_top(a)) < 0.01 and abs(dfb) > 1.0 and a["field"] == b["field"] and not b["trk"] and not a["trk"]:
            jumps.append((round(b["t"], 3), round(dfb, 2)))
        on = lambda f: f["cb"] is not None and -5 <= f["fy"] - f["cb"] <= 60
        if on(a) and on(b) and not a["trk"] and not b["trk"]:
            d = (b["cb"] - a["cb"]) - (b["fy"] - a["fy"])
            if abs(d) > 1.0:
                drifts.append((round(b["t"], 3), round(d, 2)))
    # Lag: while a keyboard transition moves the keyboard above the
    # composer's resting place, how far the field strays from riding at the
    # docked gap (0 = it rides the keyboard's own curve, frame by frame).
    lags, runs = [], transitions(fs)
    dg_gap = r["docked_gap"]
    for run in runs:
        if dg_gap is None or rest_fb is None:
            break
        worst, frames_on = 0.0, 0
        for i in run:
            f = fs[i]
            if f["kb"] is None or not docked(f) or f["kb"] > rest_fb + dg_gap - 0.5:
                continue
            frames_on += 1
            worst = max(worst, abs((f["kb"] - f["fb"]) - dg_gap))
        if frames_on:
            lags.append((round(fs[run[0]]["t"], 3), round(worst, 2), frames_on))
    r["transitions"] = len(lags)
    r["overlap_frames"] = len(overlaps)
    r["overlap_max"] = max((o[1] for o in overlaps), default=0)
    r["jump_frames"] = len(jumps)
    r["jump_max"] = max((abs(j[1]) for j in jumps), default=0)
    r["lag_max"] = max((l[1] for l in lags), default=0)
    r["drift_frames"] = len(drifts)
    r["drift_max"] = max((abs(d[1]) for d in drifts), default=0)
    r["spikes_dropped"] = sum(1 for f in fs if f.get("spike"))
    r["examples"] = {"overlap": overlaps[:6], "jump": jumps[:6], "lag (start, max pt off the gap, frames)": lags[:8], "drift": drifts[:6]}
    return r


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    frames, events = parse(args[0])
    result = analyze(frames)
    result["events"] = len(events)
    if "--json" in args:
        print(json.dumps(result, indent=1))
        return
    print(f"{args[0]}: {result['frames']} frames, {result['events']} keyboard notifications")
    if "error" in result:
        print("  " + result["error"])
        return
    for size, r in result["sizes"].items():
        print(f"  window {size}: {r['frames']} frames, rest fb {r['rest_fb']}, docked gap {r['docked_gap']}")
        print(f"    overlap {r['overlap_frames']} (max {r['overlap_max']}), jump {r['jump_frames']} (max {r['jump_max']}), "
              f"lag max {r['lag_max']} over {r['transitions']} transitions, drift {r['drift_frames']} (max {r['drift_max']}), "
              f"spikes dropped {r['spikes_dropped']}")
        for k, ex in r["examples"].items():
            if ex:
                print(f"    {k} e.g. {ex}")
    if "--frames" in args:
        for f in frames:
            print(f)


if __name__ == "__main__":
    main()
