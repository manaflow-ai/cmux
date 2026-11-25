#!/usr/bin/env python3
"""The instant-list bench's small/god/ratio table (cmux-next-ios/design/instant-perf.md).

Reads every *.jsonl report in a directory (one JSON object per line, as
CmuxMobileInstantPerfTests writes them to CMUX_INSTANT_PERF_OUT) and prints a
Markdown table: the CI job log and $GITHUB_STEP_SUMMARY show it.

    python3 cmux-next-ios/scripts/instant_perf_table.py DIR
"""

import json
import pathlib
import sys


def status(row):
    failing = set(row.get("failing", []))
    known = set(row.get("known_red", []))
    if failing - known:
        return "RED: " + ", ".join(sorted(failing - known))
    if failing:
        return "known-red: " + ", ".join(sorted(failing))
    if known:
        return "pass (known-red declared: " + ", ".join(sorted(known)) + "; remove it)"
    return "pass"


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    rows = []
    for path in sorted(root.glob("*.jsonl")):
        for line in path.read_text().splitlines():
            line = line.strip()
            if line.startswith("INSTANTPERF "):
                line = line[len("INSTANTPERF "):]
            if not line.startswith("{"):
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    print("### Instant list bench: small vs god")
    print()
    if not rows:
        print(f"No reports in {root} (the bench did not run, or could not write its report).")
        return
    print("| platform | metric | small ms | god ms | ratio | target ms | budget ms | status |")
    print("|---|---|---:|---:|---:|---:|---:|---|")
    for row in rows:
        print("| {platform} | {metric} | {small:.2f} | {god:.2f} | {ratio:.2f}x | {target:g} | {budget:g} | {status} |".format(
            platform=row.get("platform", "?"), metric=row.get("metric", "?"),
            small=row.get("small_ms", float("nan")), god=row.get("god_ms", float("nan")),
            ratio=row.get("ratio", float("nan")), target=row.get("target_ms", 0), budget=row.get("budget_ms", 0),
            status=status(row)))
    print()
    print("Ratio = god / max(small, 1 ms), at most 1.2x; budget = 3x target. Notes:")
    print()
    for row in rows:
        if row.get("note"):
            print(f"- {row.get('platform')} {row.get('metric')}: {row['note']}")


if __name__ == "__main__":
    main()
