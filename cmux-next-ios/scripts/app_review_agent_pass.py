#!/usr/bin/env python3
"""Agent reviewer pass: Claude plays the Apple reviewer on a booted simulator.

It installs the built app fresh, then drives it only through the simulator
(`axe` for taps, typing and the accessibility tree, `xcrun simctl io` for
screenshots), following cmux-next-ios/AppStoreReview/reviewer-setup.md the way an Apple
reviewer reads it. It saves a screenshot per step and writes every confusing
moment, dead end, unclear copy or broken control as a finding. Never a real
person's browser or desktop: the agent's tools are limited to axe, simctl and
reading files.

  app_review_agent_pass.py --udid UDID --app path/CmuxMobileApp.app \
      --setup cmux-next-ios/AppStoreReview/reviewer-setup.md --out DIR --findings out.json

Findings are warnings in the gate report (an agent's judgement), except a
crash or a step it could not get past, which it marks blocking. A pass that
judged nothing (axe or claude missing, the agent failed or wrote no findings
array, or it took no screenshot) is itself a blocker and exits 1.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

PROMPT = """You are an Apple App Review reviewer testing the cmux iOS app on an iPad
or iPhone simulator. You have no Mac and you have never seen cmux before.
It is an iPhone app; on an iPad it runs in compatibility mode, and App Review
judges it there too.

Simulator UDID: {udid}. The app is installed fresh (bundle id {bundle_id}).
Your only tools are shell commands:
  - `axe describe-ui --udid {udid}` prints the accessibility tree with frames.
  - `axe tap -x X -y Y --udid {udid}`, `axe type 'text' --udid {udid}`,
    `axe swipe --start-x .. --start-y .. --end-x .. --end-y .. --udid {udid}`.
  - `xcrun simctl io {udid} screenshot {out}/step-NN-name.png` then Read the PNG
    to look at it. Take one for EVERY step, numbered in order.
  - `xcrun simctl launch {udid} {bundle_id}` / `xcrun simctl terminate ...`.

The reviewer instructions from App Store Connect are below. Follow them as
written, in order, as a reviewer would, starting from a fresh launch. This
is a debug build, so its sign-in buttons sign in a local sample account
without a password: use them. Walk sign-in (every provider), Home, Chief
(open it and send a message; a reply should come), Workspaces, Feed and
Settings (every row and page). Open Settings > Account and tap Delete
Account to see that it asks first, then cancel: never confirm a deletion or
sign out until everything else is done.

Judge like App Review: guideline 2.1 (completeness, nothing broken, no dead
ends, no button that does nothing), 2.3 (accurate), 4.0 (design:
truncation, overlapping text, layout glitches, inconsistent styling,
confusing copy), 4.8 (Sign in with Apple offered beside Google and GitHub),
5.1 (permissions explained before the prompt; account deletion in the app).
The app sells nothing, so there are no purchases to find. Also anything that
would embarrass the team.

When done, write ONLY a JSON array to {findings} where each item is
{{"severity": "blocker"|"warning"|"info", "guideline": "2.1(a)",
"message": "what a reviewer would write", "where": "step-NN-name.png"}}.
Use "blocker" only for a crash, a step you could not get past, or a control
that does nothing. An empty array means you found nothing.

--- reviewer-setup.md ---
{setup}
"""


def setup_text(path: Path) -> str:
    """The reviewer notes; a source without them is walked as a first-time
    reviewer would (cmux-next-ios/AppStoreReview arrives in its own PR)."""
    try:
        return path.read_text()
    except OSError:
        return "(This source has no reviewer-setup.md. Walk the app as a first-time reviewer would.)"


def bundle_id(app: Path) -> str:
    out = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(app / "Info.plist")], text=True)
    return out.strip()


def unjudged(findings: Path, rule: str, message: str, where: str = "") -> int:
    """The pass judged nothing: a blocker the report shows, and a red step.
    It used to be a warning and exit 0, so a pass with no axe on the runner
    looked green for weeks (job 132387096997 and every run after it)."""
    findings.write_text(json.dumps([{"severity": "blocker", "guideline": "2.1", "rule": rule,
                                     "source": "agent reviewer pass", "message": message, "where": where}], indent=2))
    print(f"::error::agent reviewer pass: {message}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--setup", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--findings", required=True)
    parser.add_argument("--max-turns", default="80")
    args = parser.parse_args(argv)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    findings = Path(args.findings)
    app = Path(args.app)
    missing = [tool for tool in ("axe", "claude") if not shutil.which(tool)]
    if missing:
        return unjudged(findings, "agent.unavailable", f"the agent pass could not run: {' and '.join(missing)} not installed")
    bid = bundle_id(app)
    subprocess.run(["xcrun", "simctl", "uninstall", args.udid, bid], check=False)
    subprocess.run(["xcrun", "simctl", "install", args.udid, str(app)], check=True)
    subprocess.run(["xcrun", "simctl", "launch", args.udid, bid], check=False)

    prompt = PROMPT.format(udid=args.udid, bundle_id=bid, out=out, findings=findings,
                           setup=setup_text(Path(args.setup)))
    # A findings file left from an earlier run is never this run's verdict.
    findings.unlink(missing_ok=True)
    try:
        proc = subprocess.run(
            ["claude", "-p", prompt,
             "--allowedTools", "Bash(axe:*)", "Bash(xcrun simctl:*)", "Read", "Write",
             "--max-turns", args.max_turns, "--output-format", "json"],
            capture_output=True, text=True, timeout=45 * 60, cwd=out,
            env=dict(os.environ),
        )
    except subprocess.TimeoutExpired as timeout:
        for name, text in (("transcript.json", timeout.stdout), ("stderr.txt", timeout.stderr)):
            (out / name).write_text(text.decode(errors="replace") if isinstance(text, bytes) else (text or ""))
        return unjudged(findings, "agent.no-verdict", "the agent ran past 45 minutes with no verdict", str(out))
    (out / "transcript.json").write_text(proc.stdout or "")
    (out / "stderr.txt").write_text(proc.stderr or "")
    try:
        items = json.loads(findings.read_text())
        assert isinstance(items, list)
    except (OSError, json.JSONDecodeError, AssertionError):
        items = None
    detail = (proc.stderr or proc.stdout or "").strip().splitlines()[-1:] or ["no output"]
    if items is None:
        return unjudged(findings, "agent.no-verdict",
                        f"the agent exited {proc.returncode} with no findings array ({detail[0][:200]});"
                        " read transcript.json and stderr.txt", str(out))
    if proc.returncode != 0:
        # A verdict it wrote before stopping (out of turns, say) still counts,
        # and says the walk may be partial.
        items.append({"severity": "warning", "guideline": "-",
                      "message": f"the agent exited {proc.returncode} after writing its findings, so its walk may be"
                                 f" incomplete ({detail[0][:200]})", "where": str(out)})
    screens = len(list(out.glob("step-*.png")))
    if not screens:
        return unjudged(findings, "agent.no-walk",
                        "the agent wrote a verdict without one screenshot of the app, so it never looked at it", str(out))
    normalized = []
    for item in items:
        normalized.append({
            "rule": "agent.reviewer",
            "guideline": str(item.get("guideline", "-")),
            "severity": item.get("severity") if item.get("severity") in ("blocker", "warning", "info") else "warning",
            "source": "agent reviewer pass",
            "message": str(item.get("message", ""))[:400],
            "where": str(item.get("where", "")),
        })
    findings.write_text(json.dumps(normalized, indent=2))
    print(f"agent pass: {len(normalized)} findings, {screens} screenshots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
