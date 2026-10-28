#!/usr/bin/env python3
"""Reads Documents/kbd-pin-trace.txt (-cmux-mobile-kbd-pin-trace) and reports,
frame by frame, how the focused composer field follows the keyboard
(verify/keyboard-pin.md).

Per frame: kb is the keyboard's top as drawn (window points), fb the field's
bottom. Docked means a full-width keyboard whose top is above the field's
resting bottom plus the docked gap, so the field must ride it.

  gap      kb - fb while docked; it should stay at the docked gap on every
           frame of a show, hide or drag (no lag, no gap, no overlap).
  overlap  frames where the keyboard covers the field (fb > kb).
  jump     the field moved more than 1 pt in a frame while the keyboard did
           not move at all (a composer that moves on its own timeline).
  drift    while the transcript follows the newest content and no finger is
           down, the content's bottom moved differently from the field's.
  rest     the field's bottom with no keyboard; it should not change.

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
        for k in ("fy", "fb", "cb", "off", "inb"):
            f[k] = float(kv[k]) if k in kv else None
        f["fr"] = kv.get("fr") == "1"
        f["trk"] = kv.get("trk") == "1"
        frames.append(f)
    return frames, events


def analyze(frames):
    out = {"frames": len(frames)}
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
    dg = r["docked_gap"]
    rest_fb = r["rest_fb"]
    overlaps, jumps, lags, drifts = [], [], [], []
    for a, b in zip(fs, fs[1:]):
        kb_a = a["kb"] if a["kb"] is not None else a["winh"]
        kb_b = b["kb"] if b["kb"] is not None else b["winh"]
        if docked(b) and b["fb"] > b["kb"] + 0.5:
            overlaps.append((round(b["t"], 3), round(b["fb"] - b["kb"], 2)))
        dfb = b["fb"] - a["fb"]
        if abs(kb_b - kb_a) < 0.01 and abs(dfb) > 1.0 and a["field"] == b["field"] and not b["trk"]:
            jumps.append((round(b["t"], 3), round(dfb, 2)))
        if dg is not None and rest_fb is not None and docked(b) and b["kb"] < rest_fb + dg - 0.5:
            dev = (b["kb"] - b["fb"]) - dg
            if abs(dev) > 0.75:
                lags.append((round(b["t"], 3), round(dev, 2), round(b["kb"], 1)))
        if (a["cb"] is not None and b["cb"] is not None and not b["trk"] and not a["trk"]
                and a["fy"] - a["cb"] < 60 and b["fy"] - b["cb"] < 60):
            d = (b["cb"] - a["cb"]) - (b["fy"] - a["fy"])
            if abs(d) > 1.0:
                drifts.append((round(b["t"], 3), round(d, 2)))
    r["overlap_frames"] = len(overlaps)
    r["overlap_max"] = max((o[1] for o in overlaps), default=0)
    r["jump_frames"] = len(jumps)
    r["jump_max"] = max((abs(j[1]) for j in jumps), default=0)
    r["lag_frames"] = len(lags)
    r["lag_max"] = max((abs(l[1]) for l in lags), default=0)
    r["drift_frames"] = len(drifts)
    r["drift_max"] = max((abs(d[1]) for d in drifts), default=0)
    r["examples"] = {"overlap": overlaps[:6], "jump": jumps[:6], "lag": lags[:6], "drift": drifts[:6]}
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
              f"lag {r['lag_frames']} (max {r['lag_max']}), drift {r['drift_frames']} (max {r['drift_max']})")
        for k, ex in r["examples"].items():
            if ex:
                print(f"    {k} e.g. {ex}")
    if "--frames" in args:
        for f in frames:
            print(f)


if __name__ == "__main__":
    main()
