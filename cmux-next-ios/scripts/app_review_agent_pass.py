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
crash or a step it could not get past, which it marks blocking.
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--setup", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--findings", required=True)
    parser.add_argument("--max-turns", default="80")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    findings = Path(args.findings)
    app = Path(args.app)
    bid = bundle_id(app)
    if not shutil.which("axe") or not shutil.which("claude"):
        findings.write_text(json.dumps([{"severity": "warning", "guideline": "-", "rule": "agent.unavailable",
                                         "source": "agent reviewer pass",
                                         "message": "the agent pass could not run (axe or claude missing)", "where": ""}]))
        return 0
    subprocess.run(["xcrun", "simctl", "uninstall", args.udid, bid], check=False)
    subprocess.run(["xcrun", "simctl", "install", args.udid, str(app)], check=True)
    subprocess.run(["xcrun", "simctl", "launch", args.udid, bid], check=False)

    prompt = PROMPT.format(udid=args.udid, bundle_id=bid, out=out, findings=findings,
                           setup=setup_text(Path(args.setup)))
    proc = subprocess.run(
        ["claude", "-p", prompt,
         "--allowedTools", "Bash(axe:*)", "Bash(xcrun simctl:*)", "Read", "Write",
         "--max-turns", args.max_turns, "--output-format", "json"],
        capture_output=True, text=True, timeout=45 * 60, cwd=out,
        env=dict(os.environ),
    )
    (out / "transcript.json").write_text(proc.stdout or "")
    (out / "stderr.txt").write_text(proc.stderr or "")
    try:
        items = json.loads(findings.read_text())
        assert isinstance(items, list)
    except (OSError, json.JSONDecodeError, AssertionError):
        items = [{"severity": "warning", "guideline": "-", "message": "the agent pass wrote no findings file; read its transcript", "where": str(out)}]
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
    print(f"agent pass: {len(normalized)} findings, {len(list(out.glob('step-*.png')))} screenshots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
