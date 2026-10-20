#!/usr/bin/env python3
"""Summarize framelog.jsonl windows (FrameIntervalLog, G-04).

usage: summarize.py FILE.jsonl [--json]
Prints each window and the pooled intervals of all autoscroll windows:
p50/p90/p95/p99/max (ms), hitches (> 1.5 frames), dropped frames, hitch ms/s.
"""
import json
import math
import sys


def stats(ms, expected):
    s = sorted(ms)
    if not s:
        return {}

    def pct(p):
        return s[min(len(s) - 1, max(0, math.ceil(p * len(s)) - 1))]

    hitches = [v for v in s if v > expected * 1.5]
    dropped = sum(max(1, round(v / expected) - 1) for v in hitches)
    late = sum(v - expected for v in hitches)
    dur = sum(s) / 1000
    return {
        "frames": len(s), "expected": round(expected, 2), "p50": pct(.5), "p90": pct(.9), "p95": pct(.95),
        "p99": pct(.99), "max": s[-1], "hitches": len(hitches), "dropped": dropped,
        "hitch_ms_per_s": round(late / dur, 1) if dur else 0, "dur_s": round(dur, 2),
    }


def main():
    path = sys.argv[1]
    rows = [json.loads(line) for line in open(path) if line.strip().startswith("{")]
    pooled, expected = [], None
    for r in rows:
        ms = r.get("intervalsMs") or []
        st = stats(ms, r["expectedMs"]) if ms else {}
        print(f"{r['label']:28} " + " ".join(f"{k}={v}" for k, v in st.items()))
        if r["label"].startswith("feed-autoscroll"):
            pooled += ms
            expected = r["expectedMs"]
    if pooled:
        st = stats(pooled, expected)
        print(f"{'POOLED autoscroll':28} " + " ".join(f"{k}={v}" for k, v in st.items()))
        if "--json" in sys.argv:
            print(json.dumps(st))


if __name__ == "__main__":
    main()
