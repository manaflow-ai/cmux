#!/usr/bin/env python3
"""Judge a PagedList stress run (PagedListStressUITests) for CI: layout shift fails, hitches are reported.

    pagedlist_stress_gate.py EVIDENCE [--suite FILE] [--summary FILE]

EVIDENCE is what `scripts/ci/cmux-next-ios-sim.sh test ui=PagedListStressUITests` leaves: its
`artifacts/ios-sim` folder or evidence.zip (the records are read by the `ios-pagedlist` bench's own
parser, so a record means the same thing here and in `cmux-bench`).

Exit 1 when:
  - a row being read moved in a frame the scroll does not explain (`frameShift` over 0.5 pt), or a
    landing page moved it (`maxShift` over 0.5 pt): the list's guarantee (verify/paged-list.md);
  - a case left no record, or a record that measured nothing (30 or fewer layout passes sampled, or a
    load that changed nothing): a run that measured nothing is not a pass.

Hitches, the worst frame, dropped frames and memory are printed and written to the job summary, never
failed on: they depend on the runner (verify/paged-list.md, "Stress bench"), and the XCTest suite's own
hitch assertions are why its xcodebuild step does not decide the job.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "bench"))

from benches.ios_pagedlist import IosPagedList  # noqa: E402

SHIFT_BAR_PT = 0.5
MIN_SAMPLES = 30
SUITE = ROOT / "cmux-next-ios" / "UITests" / "PagedListStressUITests.swift"
CASE = re.compile(r'func test\w+\(\)\s*\{\s*stress\("(\w+)",\s*\.(\w+),\s*"(\w+)"')


def expected_cases(suite: Path) -> list[str]:
    """`STRESS-<direction>-<speed>-<load>` for every test method in the suite."""
    return [f"STRESS-{d}-{s}-{load}" for d, s, load in CASE.findall(suite.read_text(encoding="utf-8"))]


def _num(hud: dict, key: str) -> float | None:
    value = hud.get(key)
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _fmt(value: float | None, digits: int = 2) -> str:
    if value is None:
        return "–"
    text = f"{value:.{digits}f}"
    return text.rstrip("0").rstrip(".") if "." in text else text


def judge(cases: dict[str, dict], expected: list[str]) -> tuple[list[str], list[str], list[str]]:
    """(failures, warnings, table rows) for the records in `cases`."""
    failures: list[str] = []
    warnings: list[str] = []
    rows: list[str] = []
    for name in expected:
        if name not in cases:
            failures.append(f"{name}: no record (the case did not run or crashed before it measured)")
            rows.append(f"| {name} | – | – | – | – | – | – | – | no record |")
    for name in sorted(cases):
        record = cases[name]
        hud = record.get("hud") or {}
        shift, frames = _num(hud, "frameShift"), _num(hud, "shiftedFrames")
        landing, hitch = _num(hud, "maxShift"), _num(hud, "hitchMsPerS")
        worst, dropped = _num(hud, "worstMs"), _num(hud, "dropped")
        rows_in_memory, samples, changes = _num(hud, "inMemory"), _num(hud, "samples"), _num(hud, "changes")
        verdict = []
        if shift is None or landing is None:
            failures.append(f"{name}: the record has no frameShift or maxShift")
            verdict.append("no shift measure")
        else:
            if shift > SHIFT_BAR_PT:
                failures.append(f"{name}: a row being read moved {_fmt(shift)} pt in a frame the scroll does not explain "
                                f"({_fmt(frames, 0)} frames)")
                verdict.append("SHIFT")
            if landing > SHIFT_BAR_PT:
                failures.append(f"{name}: a landing page moved the reader {_fmt(landing)} pt")
                verdict.append("LANDING SHIFT")
        if samples is not None and samples <= MIN_SAMPLES:
            failures.append(f"{name}: the frame-shift measure sampled only {samples:.0f} layout passes")
            verdict.append("not measured")
        if changes is not None and changes <= 0:
            failures.append(f"{name}: the load changed nothing")
            verdict.append("no load")
        window = record.get("window")
        if isinstance(window, int) and rows_in_memory is not None and rows_in_memory > window + 150:
            warnings.append(f"{name}: {rows_in_memory:.0f} row values in memory with a window of {window}")
        if hitch is not None and hitch > 10 and record.get("load") != "busy":
            warnings.append(f"{name}: scrolling hitched {_fmt(hitch, 1)} ms a second (reported, not gated)")
        rows.append(f"| {name} | {_fmt(shift)} | {_fmt(frames, 0)} | {_fmt(landing)} | {_fmt(hitch, 1)} | "
                    f"{_fmt(worst, 1)} | {_fmt(dropped, 0)} | {_fmt(rows_in_memory, 0)} | "
                    f"{', '.join(verdict) or 'ok'} |")
    return failures, warnings, rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("evidence", type=Path, help="artifacts/ios-sim folder or its evidence.zip")
    parser.add_argument("--suite", type=Path, default=SUITE, help="the stress suite's source (for its case list)")
    parser.add_argument("--summary", type=Path, default=Path(os.environ["GITHUB_STEP_SUMMARY"])
                        if os.environ.get("GITHUB_STEP_SUMMARY") else None)
    args = parser.parse_args(argv)
    if not args.evidence.exists():
        print(f"pagedlist_stress_gate: no evidence at {args.evidence}", file=sys.stderr)
        return 1
    expected = expected_cases(args.suite)
    if not expected:
        print(f"pagedlist_stress_gate: no stress cases found in {args.suite}", file=sys.stderr)
        return 1
    cases = IosPagedList._cases(args.evidence)
    failures, warnings, rows = judge(cases, expected)
    head = "| case | frame shift pt | shifted frames | landing shift pt | hitch ms/s | worst frame ms | dropped | rows in memory | verdict |"
    lines = [
        "## PagedList stress (iOS simulator)",
        "",
        f"{len(cases)} of {len(expected)} cases measured. Fails on layout shift over {SHIFT_BAR_PT} pt or a case that "
        "measured nothing; hitches, frame times and memory are reported only.",
        "",
        head,
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
        *rows,
        "",
    ]
    if failures:
        lines += ["### Failures", "", *(f"- {f}" for f in failures), ""]
    if warnings:
        lines += ["### Reported, not gated", "", *(f"- {w}" for w in warnings), ""]
    text = "\n".join(lines)
    print(text)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as fh:
            fh.write(text + "\n")
    for failure in failures:
        print(f"::error::PagedList stress: {failure}")
    for warning in warnings:
        print(f"::warning::PagedList stress: {warning}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
