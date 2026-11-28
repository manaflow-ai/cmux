#!/usr/bin/env python3
"""CSV from upload-netem-bench.sh -> markdown table: finish rate, median and p90 of total/last-byte/reply ms (finished runs)."""
import csv, statistics, sys
from collections import defaultdict
rows = list(csv.DictReader(open(sys.argv[1])))
cells = defaultdict(list)
for r in rows:
    cells[(r["transport"], int(r["size_mb"]), r["profile"], r["load"])].append(r)
def pct(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]
def fmt(v): return "-" if not v else f"{statistics.median(v)/1000:.1f} / {pct(v,90)/1000:.1f}"
print("| transport | MB | profile | load | n | finished | total s (med/p90) | last byte s | Mac reply s | open ms (med) | max stall s | failures |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for k in sorted(cells):
    rs = cells[k]; ok = [r for r in rs if r["finished"] == "y"]
    col = lambda n, src=ok: [int(r[n]) for r in src]
    fails = sorted({r["code"].strip('"')[:40] for r in rs if r["finished"] != "y"})
    stall = max(int(r["max_stall_ms"]) for r in rs) / 1000
    op = f"{statistics.median(col('open_ms')):.0f}" if ok else "-"
    print(f"| {k[0]} | {k[1]} | {k[2]} | {k[3]} | {len(rs)} | {len(ok)}/{len(rs)} | {fmt(col('total_ms'))} | {fmt(col('last_byte_ms'))} | {fmt(col('reply_ms'))} | {op} | {stall:.0f} | {'; '.join(fails)} |")

# PAIRCELL JSON lines (cmuxterm-hq transport-pair-matrix rows), beside the CSV: median total, p90 total, finish rate.
import json
engine_label = {"current": "old"}
with open(sys.argv[1].removesuffix(".csv") + ".paircell.jsonl", "w") as out:
    for k in sorted(cells):
        rs = cells[k]; ok = [int(r["total_ms"]) for r in rs if r["finished"] == "y"]
        base = {"pair": "ios-mac", "path": "direct", "condition": k[2], "load": k[3], "size_mb": k[1],
                "engine": engine_label.get(rs[0]["engine"], rs[0]["engine"]), "transport": k[0], "n": len(rs)}
        for metric, value in (("upload_total_ms", statistics.median(ok) if ok else None),
                              ("upload_total_p90_ms", pct(ok, 90) if ok else None),
                              ("upload_finish_rate", len(ok) / len(rs))):
            print(json.dumps({**base, "metric": metric, "value": value}), file=out)
