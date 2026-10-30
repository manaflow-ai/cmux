#!/usr/bin/env python3
"""Summarize framelog.jsonl windows (FrameIntervalLog, G-04).

usage: summarize.py FILE.jsonl [--json]
Prints each window and the pooled intervals of all autoscroll windows:
p50/p90/p95/p99/max (ms), hitches (> 1.5 frames), dropped frames, hitch ms/s.
"""
import json
import math
import sys


def stats(ms, expected, cpu=None, frame_cpu=None):
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
        **({"main_cpu_ms_per_s": round(cpu / dur, 1)} if cpu is not None and dur else {}),
        # Frames whose main thread used more CPU than one frame's budget: the app's own hitches.
        **({"main_busy_frames": sum(1 for c in frame_cpu if c > expected),
            "main_cpu_p99": sorted(frame_cpu)[min(len(frame_cpu) - 1, math.ceil(.99 * len(frame_cpu)) - 1)]}
           if frame_cpu else {}),
    }


def main():
    path = sys.argv[1]
    rows = [json.loads(line) for line in open(path) if line.strip().startswith("{")]
    pooled, expected, cpu, frame_cpu = [], None, 0.0, []
    for r in rows:
        ms = r.get("intervalsMs") or []
        st = stats(ms, r["expectedMs"], r.get("mainThreadCPUMs"), r.get("mainThreadCPUPerFrameMs")) if ms else {}
        print(f"{r['label']:28} " + " ".join(f"{k}={v}" for k, v in st.items()))
        if r["label"].startswith("feed-autoscroll"):
            pooled += ms
            expected = r["expectedMs"]
            frame_cpu += r.get("mainThreadCPUPerFrameMs") or []
            cpu = None if cpu is None or r.get("mainThreadCPUMs") is None else cpu + r["mainThreadCPUMs"]
    if pooled:
        st = stats(pooled, expected, cpu, frame_cpu)
        print(f"{'POOLED autoscroll':28} " + " ".join(f"{k}={v}" for k, v in st.items()))
        if "--json" in sys.argv:
            print(json.dumps(st))


if __name__ == "__main__":
    main()
