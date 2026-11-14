#!/usr/bin/env python3
"""Summarize one energy bench run: the app's `top` samples into one JSON line, or a table row.

    energy_summary.py TOP_TXT PID RUN PHASE   > RUN.json   (from `top -l N -s 1 -pid PID -stats pid,cpu,idlew,power,mem`)
    energy_summary.py --row RUN.json                       (the SUMMARY.md row)

top's first sample is dropped: its CPU and POWER are averaged since the process started. IDLEW is
read either way top prints it: when the column only grows (a count since launch), the rate is its
growth over the sampled seconds; otherwise each sample is already a per-interval count. The method
and the bench are in cmux-next-ios/verify/energy.md.
"""
import json
import re
import statistics
import sys

UNITS = {"B": 1 / 1024 / 1024, "K": 1 / 1024, "M": 1.0, "G": 1024.0}


def megabytes(word):
    match = re.match(r"^([0-9.]+)([BKMG])?[+-]?$", word)
    if not match:
        return None
    return float(match.group(1)) * UNITS[match.group(2) or "B"]


def samples(path, pid):
    rows = []
    for line in open(path, errors="replace"):
        words = line.split()
        if len(words) == 5 and words[0] == pid:
            try:
                cpu, idlew, power = float(words[1]), float(words[2]), float(words[3])
            except ValueError:
                continue
            mem = megabytes(words[4])
            if mem is not None:
                rows.append({"cpu": cpu, "idlew": idlew, "power": power, "mem": mem})
    return rows


def summarize(path, pid, run, phase):
    rows = samples(path, pid)[1:]
    if not rows:
        return None
    seconds = len(rows)
    idlew = [r["idlew"] for r in rows]
    # A count since launch never falls and nearly always rises; per-second counts go up and down.
    steps = list(zip(idlew, idlew[1:]))
    cumulative = len(steps) >= 2 and all(y >= x for x, y in steps) and sum(y > x for x, y in steps) >= 0.9 * len(steps)
    growth = (idlew[-1] - idlew[0]) / max(seconds - 1, 1)
    wakeups = growth if cumulative else statistics.mean(idlew)
    mem = [r["mem"] for r in rows]
    return {
        "run": run,
        "phase": phase,
        "seconds": seconds,
        "cpu_pct": round(statistics.mean(r["cpu"] for r in rows), 2),
        "idle_wakeups_per_s": round(wakeups, 1),
        "idlew_cumulative": cumulative,
        "idlew_mean": round(statistics.mean(idlew), 1),
        "idlew_growth_per_s": round(growth, 1),
        "power": round(statistics.mean(r["power"] for r in rows), 2),
        "mem_start_mb": round(mem[0], 1),
        "mem_end_mb": round(mem[-1], 1),
        "mem_max_mb": round(max(mem), 1),
    }


def main(argv):
    if argv[:1] == ["--row"]:
        r = json.load(open(argv[1]))
        print(f"| {r['run']} | {r['phase']} | {r['seconds']} | {r['cpu_pct']} | {r['idle_wakeups_per_s']} | "
              f"{r['power']} | {r['mem_start_mb']} | {r['mem_end_mb']} | {r['mem_max_mb']} |")
        return 0
    path, pid, run, phase = argv
    summary = summarize(path, pid, run, phase)
    if summary is None:
        print(f"energy_summary.py: no samples for pid {pid} in {path}", file=sys.stderr)
        return 1
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
