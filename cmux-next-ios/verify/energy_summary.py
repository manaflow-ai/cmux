#!/usr/bin/env python3
"""Summarize one energy bench run into one JSON line, or a table row.

    energy_summary.py RUSAGE_JSONL TOP_TXT PID RUN PHASE > RUN.json
    energy_summary.py --row RUN.json                       (the SUMMARY.md row)

RUSAGE_JSONL is `energy_rusage.py sample`'s output: one proc_pid_rusage reading a second. Its
counters only grow, so every rate is (last - first) / elapsed seconds:

- cpu_pct: user + system CPU time over wall time (100 is one core).
- wakeups_per_s: ri_interrupt_wkups (top's IDLEW is ri_pkg_idle_wkups, 0 on the fleet minis; kept
  as pkg_idle_wakeups_per_s).
- energy_mw: the kernel's energy estimate for the process, ri_energy_nj (nJ) per second, in
  milliwatts; ri_billed_energy when ri_energy_nj does not move (energy_source says which).
- mem_*_mb: ri_phys_footprint (the footprint Xcode and Activity Monitor show), first, last, peak.

TOP_TXT (`top -l N -s 1 -pid PID -stats pid,cpu,idlew,power,mem`, may be missing) is kept as a
cross-check in the JSON only: top_cpu_pct should agree with cpu_pct. cmux-next-ios/verify/energy.md
has the method.
"""
import json
import statistics
import sys

MB = 1024 * 1024


def readings(path):
    rows = []
    for line in open(path, errors="replace"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def top_samples(path, pid):
    rows = []
    try:
        lines = open(path, errors="replace").readlines()
    except OSError:
        return rows
    for line in lines:
        words = line.split()
        if len(words) == 5 and words[0] == pid:
            try:
                rows.append((float(words[1]), float(words[2]), float(words[3])))
            except ValueError:
                continue
    return rows[1:]  # top's first sample is averaged since launch


def rate(first, last, key, seconds):
    if key not in first or key not in last:
        return None
    return (last[key] - first[key]) / seconds


def summarize(rusage_path, top_path, pid, run, phase):
    rows = readings(rusage_path)
    if len(rows) < 2:
        return None
    first, last = rows[0], rows[-1]
    seconds = last["t"] - first["t"]
    if seconds <= 0:
        return None
    energy_nj = rate(first, last, "ri_energy_nj", seconds)
    billed = rate(first, last, "ri_billed_energy", seconds)
    if energy_nj:
        source, energy = "ri_energy_nj", energy_nj
    elif billed:
        source, energy = "ri_billed_energy", billed
    else:
        source, energy = "none", None
    mem = [r["ri_phys_footprint"] / MB for r in rows]
    summary = {
        "run": run,
        "phase": phase,
        "seconds": round(seconds, 1),
        "flavor": last.get("flavor"),
        "cpu_pct": round((last["cpu_ns"] - first["cpu_ns"]) / 1e9 / seconds * 100, 2),
        "wakeups_per_s": round(rate(first, last, "ri_interrupt_wkups", seconds), 1),
        "pkg_idle_wakeups_per_s": round(rate(first, last, "ri_pkg_idle_wkups", seconds), 1),
        "energy_mw": None if energy is None else round(energy / 1e6, 2),
        "energy_source": source,
        "energy_nj_mw": None if energy_nj is None else round(energy_nj / 1e6, 2),
        "billed_energy_mw": None if billed is None else round(billed / 1e6, 2),
        "instructions_per_s": rate(first, last, "ri_instructions", seconds),
        "mem_start_mb": round(mem[0], 1),
        "mem_end_mb": round(mem[-1], 1),
        "mem_max_mb": round(max(mem), 1),
    }
    top = top_samples(top_path, pid)
    if top:
        summary["top_cpu_pct"] = round(statistics.mean(t[0] for t in top), 2)
        summary["top_idlew_mean"] = round(statistics.mean(t[1] for t in top), 1)
        summary["top_power_mean"] = round(statistics.mean(t[2] for t in top), 2)
    return summary


def main(argv):
    if argv[:1] == ["--row"]:
        r = json.load(open(argv[1]))
        energy = "-" if r["energy_mw"] is None else r["energy_mw"]
        print(f"| {r['run']} | {r['phase']} | {r['seconds']} | {r['cpu_pct']} | {r['wakeups_per_s']} | "
              f"{energy} | {r['mem_start_mb']} | {r['mem_end_mb']} | {r['mem_max_mb']} |")
        return 0
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    rusage_path, top_path, pid, run, phase = argv
    summary = summarize(rusage_path, top_path, pid, run, phase)
    if summary is None:
        print(f"energy_summary.py: fewer than two readings for pid {pid} in {rusage_path}", file=sys.stderr)
        return 1
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
