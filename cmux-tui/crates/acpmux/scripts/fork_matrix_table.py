#!/usr/bin/env python3
"""Markdown table of fork_matrix.py results: harness x case, passes over runs.

    python3 -I fork_matrix_table.py RESULTS.jsonl [MORE.jsonl ...]

A cell is `passes/runs`; `unsupported` (the harness offers no fork, refused with its
reason) and `n/a` count apart and are shown as such.
"""
import collections
import json
import sys

CASES = ["seed", "transcript", "recall", "original", "isolation", "concurrent",
         "fork_of_fork", "busy", "restart", "empty"]

cells: dict = collections.defaultdict(collections.Counter)
harnesses: list = []
for path in sys.argv[1:]:
    for line in open(path):
        row = json.loads(line)
        h = row["harness"] + (f" ({row['model']})" if "/" in row.get("model", "") else "")
        if h not in harnesses:
            harnesses.append(h)
        cells[(h, row["case"])][row["result"]] += 1

print("| harness | " + " | ".join(CASES) + " |")
print("|---" * (len(CASES) + 1) + "|")
for h in harnesses:
    out = []
    for c in CASES:
        n = cells[(h, c)]
        total = sum(n.values())
        if not total:
            out.append("-")
        elif n["unsupported"]:
            out.append(f"unsupported {n['unsupported']}/{total}")
        elif n["n/a"] == total:
            out.append("n/a")
        else:
            out.append(f"{n['pass']}/{total - n['n/a']}")
    print(f"| {h} | " + " | ".join(out) + " |")
