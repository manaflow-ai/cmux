"""Round-8 verifier: the in-app frame log (Documents/frame-log.ndjson) for a time window.
Blank runs = consecutive frames with blank=true (the app's own flag); longest frames.

    python3 v8v_fl.py T0 T1 [OUT.json]     (epoch seconds)
"""
import json
import os
import subprocess
import sys

U = json.load(open(os.path.expanduser("~/cmux-next-ios-e2e/termqa-state.json")))["udid"]


def rows(t0, t1):
    d = subprocess.run(["xcrun", "simctl", "get_app_container", U, os.environ.get("TQ_BUNDLE", "dev.cmux.mobile"), "data"], capture_output=True, text=True).stdout.strip()
    out = []
    with open(os.path.join(d, "Documents", "frame-log.ndjson")) as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if t0 <= r["t"] <= t1:
                out.append(r)
    return out


def summary(t0, t1):
    rs = rows(t0, t1)
    runs, cur = [], None
    for r in rs:
        if r.get("blank"):
            if cur is None:
                cur = [r["t"], r["t"], 0, r["surface"]]
            cur[1] = r["t"]; cur[2] += 1
        elif cur is not None:
            runs.append(cur); cur = None
    if cur:
        runs.append(cur)
    dts = sorted((r["dt_ms"] for r in rs), reverse=True)
    longest = sorted(rs, key=lambda r: -r["dt_ms"])[:10]
    return {"frames": len(rs), "blank_frames": sum(1 for r in rs if r.get("blank")),
            "blank_runs": [{"t0": round(a, 3), "t1": round(b, 3), "frames": n, "surface": s} for a, b, n, s in runs],
            "blank_runs_over_1_frame": sum(1 for x in runs if x[2] > 1),
            "dt_max": dts[0] if dts else None, "dt_top10": dts[:10],
            "frames_over_100ms": sum(1 for x in dts if x > 100), "frames_over_250ms": sum(1 for x in dts if x > 250),
            "longest": [{"t": round(r["t"], 3), "dt_ms": r["dt_ms"], "phase": r["phase"], "work_ms": r["work_ms"], "parts": r.get("parts")} for r in longest]}


if __name__ == "__main__":
    s = summary(float(sys.argv[1]), float(sys.argv[2]))
    if len(sys.argv) > 3:
        json.dump(s, open(sys.argv[3], "w"), indent=1)
    print(json.dumps({k: v for k, v in s.items() if k != "longest"}, indent=1))
