#!/usr/bin/env python3
"""First-user journey (iOS): results.json and summary.md from one simulator run.

Reads the `FUJ {json}` lines FirstUserJourneyUITests prints into the xcodebuild
log, and the screenshots `xcrun xcresulttool export attachments` wrote (its
manifest.json names each by the attachment name the test gave it). Writes the
shared first-user-journey schema (surface "ios"; one cell per journey,
`ios/<screen>`; harness and state null), summary.md, and copies each red's
screenshot under screens/ so the artifact is self-contained.

    first_user_journey_report.py --log journey.log --attachments screens-raw \\
        --exit-code 0 --build SHA --run-url URL --out out/

A cell that began and never finished, or never began, is red (`crash`): a
journey that stopped is never a pass.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import sys
from pathlib import Path

CELLS = (
    "ios/sign-in", "ios/onboarding", "ios/pairing", "ios/home", "ios/workspaces", "ios/feed",
    "ios/chat", "ios/settings", "ios/face-id", "ios/ssh-host", "ios/errors", "ios/layout",
)
RULES = (
    "error-without-next-step", "raw-error-code", "dead-button", "permanent-spinner",
    "permission-prompt-without-explanation", "layout-break", "console-error", "crash",
)
LINE = re.compile(r"FUJ (\{.*\})\s*$")
SCRUB = [
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "<email>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"(?i)(token|secret|password|key)[=:]\s*\S+"), r"\1=<redacted>"),
]


def scrub(text: str, limit: int = 200) -> str:
    for pattern, repl in SCRUB:
        text = pattern.sub(repl, text)
    return text[:limit]


def read_events(logs: list[Path]) -> list[dict]:
    events: list[dict] = []
    for log in logs:
        if not log.is_file():
            continue
        for line in log.read_text(errors="replace").splitlines():
            match = LINE.search(line)
            if not match:
                continue
            try:
                events.append(json.loads(match.group(1)))
            except json.JSONDecodeError:
                continue
    return events


def attachment_index(root: Path | None) -> dict[str, Path]:
    """Attachment name (as the test gave it) -> exported file."""
    index: dict[str, Path] = {}
    if root is None or not root.is_dir():
        return index
    for manifest in root.rglob("manifest.json"):
        try:
            data = json.loads(manifest.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        for test in data if isinstance(data, list) else []:
            for item in test.get("attachments", []):
                exported = item.get("exportedFileName")
                human = item.get("suggestedHumanReadableName") or ""
                if exported:
                    index[human] = manifest.parent / exported
    return index


def find_shot(index: dict[str, Path], name: str) -> Path | None:
    if not name:
        return None
    for human, path in index.items():
        if human == name or human.startswith(name + "_") or human.startswith(name + "."):
            return path
    return None


def build(events: list[dict], index: dict[str, Path], out: Path, exit_code: int) -> list[dict]:
    cells: dict[str, dict] = {}
    began: set[str] = set()
    finished: set[str] = set()
    for event in events:
        cell = event.get("cell") or ""
        if not cell:
            continue
        entry = cells.setdefault(cell, {"cell": cell, "harness": None, "state": None, "outcome": "pass",
                                        "steps": 0, "reds": [], "notes": [], "skipped": None})
        kind = event.get("event")
        if kind == "begin":
            began.add(cell)
        elif kind == "finish":
            finished.add(cell)
            entry["steps"] = max(entry["steps"], int(event.get("steps") or 0))
        elif kind == "skip":
            entry["skipped"] = scrub(event.get("detail", ""))
        elif kind == "note":
            entry["notes"].append(scrub(event.get("detail", ""), 300))
        elif kind == "red":
            rule = event.get("rule", "")
            if rule not in RULES:
                rule = "crash"
            shot_rel = None
            shot = find_shot(index, event.get("screenshot", ""))
            if shot and shot.is_file():
                dest = out / "screens" / (event["screenshot"] + shot.suffix)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(shot, dest)
                shot_rel = str(dest.relative_to(out))
            red = {"rule": rule, "where": scrub(event.get("where", ""), 80), "step": scrub(event.get("step", ""), 120),
                   "detail": scrub(event.get("detail", "")), "screenshot": shot_rel}
            key = (red["rule"], red["where"], red["detail"])
            if key not in {(r["rule"], r["where"], r["detail"]) for r in entry["reds"]}:
                entry["reds"].append(red)
    for cell in CELLS:
        if cell not in cells:
            cells[cell] = {"cell": cell, "harness": None, "state": None, "outcome": "pass", "steps": 0,
                           "reds": [], "notes": [], "skipped": None}
    for cell, entry in cells.items():
        if cell not in began:
            entry["reds"].append({"rule": "crash", "where": cell.split("/", 1)[-1], "step": "start the cell",
                                  "detail": f"the journey never reached this cell (xcodebuild exit {exit_code})",
                                  "screenshot": None})
        elif cell not in finished:
            entry["reds"].append({"rule": "crash", "where": cell.split("/", 1)[-1], "step": "finish the cell",
                                  "detail": "the journey stopped inside this cell (a test crash or timeout)",
                                  "screenshot": None})
        if entry["reds"]:
            entry["outcome"] = "red"
        elif entry["skipped"]:
            entry["outcome"] = "skip"
    ordered = [cells[c] for c in CELLS] + [v for k, v in sorted(cells.items()) if k not in CELLS]
    return ordered


def summary(results: dict, cells: list[dict]) -> str:
    lines = ["# First-user journey: iOS (simulator)", "",
             f"Build `{results['build']}`, {results['generated_at']}" + (f", [run]({results['run_url']})" if results["run_url"] else ""),
             "", "| Cell | Outcome | Steps | Reds |", "|---|---|---|---|"]
    for cell in cells:
        rules: dict[str, int] = {}
        for red in cell["reds"]:
            rules[red["rule"]] = rules.get(red["rule"], 0) + 1
        reds = ", ".join(f"{k} x{v}" for k, v in sorted(rules.items())) or "-"
        lines.append(f"| {cell['cell']} | {cell['outcome']} | {cell['steps']} | {reds} |")
    lines += ["", "## Reds", ""]
    any_red = False
    for cell in cells:
        for red in cell["reds"]:
            any_red = True
            shot = f" ([screenshot]({red['screenshot']}))" if red.get("screenshot") else ""
            lines.append(f"- **{red['rule']}** `{red['where']}`, {red['step']}: {red['detail']}{shot}")
    if not any_red:
        lines.append("None.")
    notes = [(c["cell"], n) for c in cells for n in c.get("notes", [])] + \
            [(c["cell"], "skipped: " + c["skipped"]) for c in cells if c.get("skipped")]
    if notes:
        lines += ["", "## Notes (not judged)", ""] + [f"- `{c}`: {n}" for c, n in notes]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--log", action="append", required=True, type=Path, help="xcodebuild log (repeatable)")
    parser.add_argument("--attachments", type=Path, help="xcresulttool export attachments output")
    parser.add_argument("--exit-code", type=int, default=0)
    parser.add_argument("--build", default="")
    parser.add_argument("--run-url", default="")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    events = read_events(args.log)
    if not events:
        # The journey never started (the runner broke: a missing tool, a simulator that never booted): no cell
        # was walked, so there is no result. Writing every cell as an app crash would put a runner fault in the
        # quality report as app reds; with no results.json the report shows this surface n/a, and the run is red.
        why = f"the journey never started (xcodebuild exit {args.exit_code}, no FUJ events in its log)"
        (args.out / "summary.md").write_text(f"# First-user journey: iOS (simulator)\n\nNo result: {why}.\n")
        print(f"first-user journey (ios): {why}", file=sys.stderr)
        return 1
    index = attachment_index(args.attachments)
    cells = build(events, index, args.out, args.exit_code)
    # Every journey screenshot by its step name, for the screens that passed.
    for human, path in index.items():
        if human.startswith("fuj-") and path.is_file():
            dest = args.out / "screens" / "all" / human
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)
    results = {
        "schema": 1,
        "surface": "ios",
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "build": args.build,
        "run_url": args.run_url or None,
        "cells": [{k: c[k] for k in ("cell", "harness", "state", "outcome", "steps", "reds")} for c in cells],
        "missing_accounts": [],
    }
    (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    (args.out / "summary.md").write_text(summary(results, cells))
    reds = sum(len(c["reds"]) for c in cells)
    print(f"first-user journey (ios): {len(cells)} cells, {reds} reds, {len(events)} events")
    return 0


if __name__ == "__main__":
    sys.exit(main())
