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

A run the API never served (the CLI's result shows a 429, 529 or 5xx status,
a rate_limit or overloaded error, or zero API time and zero input tokens) ends
red as agent.api-unavailable, so the red names the shared account, not the
PR. A transient one is retried once after a backoff first; a weekly or other
usage limit is not, since a minute cannot clear it. It prints one
`::error::agent.api-unavailable {json}` marker with the CLI's fields, which
scripts/ci/base_red_excuse.py excuses when the recorded API usage was zero.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

# The launch the XCUITest walk makes (AppReviewGateUITests.launch, signed
# out), kept equal to it by tests/test_ios_app_review_gate.py: the Debug
# build's mock account (CMUX_MOBILE_MOCK_AUTH) stands in for the demo
# account App Review gets, starting on sign-in (CMUX_MOBILE_CLEAR_AUTH).
# Without it the sign-in buttons are the live ones and the agent stops
# there (gate run 43591424745).
REVIEW_LAUNCH_ARGS = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore"]
# Every launch: simctl passes a SIMCTL_CHILD_ variable to each app it
# launches, the agent's relaunches included.
REVIEW_ENV = {"CMUX_MOBILE_MOCK_AUTH": "1"}
# The first launch only, so a relaunch keeps a signed-in reviewer signed in.
FIRST_LAUNCH_ENV = {"CMUX_MOBILE_CLEAR_AUTH": "1"}
# The code the mock account's email sign-in accepts (CmuxMobileAuthModel),
# in place of the one a reviewer reads from the demo account's inbox.
MOCK_EMAIL_CODE = "424242"

# The agent's whole budget, a retry included.
AGENT_BUDGET_S = 45 * 60
# Seconds before the one retry of a run the API never served, plus up to half
# again of jitter so the gate's parallel runs do not retry together. Tests set
# it to 0.
RETRY_BACKOFF_ENV = "APP_REVIEW_AGENT_RETRY_BACKOFF_S"
DEFAULT_RETRY_BACKOFF_S = 60.0
API_UNAVAILABLE_MESSAGE = "agent pass: API unavailable (rate limited)"
# The one line a merge's classifier reads (scripts/ci/base_red_excuse.py,
# AGENT_API_UNAVAILABLE): this prefix, a space, then the evidence as JSON.
API_UNAVAILABLE_MARKER = "agent.api-unavailable"
UNSERVED_ERROR_TYPES = frozenset({"rate_limit", "rate_limit_error", "overloaded", "overloaded_error"})
USAGE_LIMIT_ERRORS = frozenset({"usage_limit_reached"})
# The CLI's own result text for a usage limit (gate run 43637095919: "You've
# hit your weekly limit · resets Nov 18 at 3am (UTC)"). It only names the
# limit and its reset once a structured field already says the API refused.
USAGE_LIMIT_TEXT = re.compile(r"\bhit your (?P<limit>[\w-]+(?: [\w-]+)?) limit\b(?:.*?\bresets (?P<resets>.+?))?\s*$",
                              re.IGNORECASE | re.DOTALL)

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
  - `xcrun simctl launch {udid} {bundle_id} {launch_args}` to relaunch
    (exactly this), `xcrun simctl terminate {udid} {bundle_id}` to quit.

The app is already launched, on its sign-in screen. The reviewer
instructions from App Store Connect are below. Follow them as written, in
order, as a reviewer would. This is a debug build running a sample account
in place of the demo account App Review gets, so sign-in needs no real
credentials and never leaves the app: "Continue with email" takes any
address (use reviewer@example.com) and then the code {code}, which stands in
for the code a reviewer reads from the demo account's inbox; Continue with
Apple, Google and GitHub each sign the sample account straight in. Sign in
by email, as the instructions do. A relaunch starts the sample account
signed in, even after a sign-out; that is this build, not a bug. Walk
sign-in, the first-run setup it leads to, Home, Chief
(open it and send a message; a reply should come), Workspaces, Feed and
Settings (every row and page). Open Settings > Account and tap Delete
Account to see that it asks first, then cancel: never confirm a deletion or
sign out until everything else is done. Last, sign out and check that Apple,
Google and GitHub each sign in too.

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


def unjudged(findings: Path, rule: str, message: str, where: str = "", api: dict | None = None) -> int:
    """The pass judged nothing: a blocker the report shows, and a red step.
    It used to be a warning and exit 0, so a pass with no axe on the runner
    looked green for weeks (job 132387096997 and every run after it). With
    API, the CLI result's evidence, the step's only error line is the marker."""
    entry = {"severity": "blocker", "guideline": "2.1", "rule": rule,
             "source": "agent reviewer pass", "message": message, "where": where}
    if api is not None:
        entry["api"] = api
    findings.write_text(json.dumps([entry], indent=2))
    if api is None:
        print(f"::error::agent reviewer pass: {message}", file=sys.stderr)
    else:
        evidence = json.dumps(api, separators=(",", ":"))
        # A workflow command's data escapes these three (GitHub's toolkit).
        evidence = evidence.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error::{API_UNAVAILABLE_MARKER} {evidence}", file=sys.stderr)
    return 1


def cli_result(stdout: str) -> dict | None:
    """The CLI's final result object: the whole of stdout with
    `--output-format json`, the last `"type": "result"` line of stream-json,
    or the last such entry of a JSON array."""
    try:
        body = json.loads(stdout)
    except json.JSONDecodeError:
        body = None
        for line in reversed(stdout.splitlines()):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(entry, dict) and entry.get("type") == "result":
                body = entry
                break
    if isinstance(body, list):
        body = next((e for e in reversed(body) if isinstance(e, dict) and e.get("type") == "result"), None)
    return body if isinstance(body, dict) else None


def count(value) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def api_unavailable(result: dict | None) -> dict | None:
    """The CLI result's evidence that the API never served the run, or None.
    Only its structured fields classify: api_error_status or error.status
    429, 529 or 5xx; api_error_type, error.type or error rate_limit or
    overloaded; api_error usage_limit_reached; or duration_api_ms 0 with
    usage.input_tokens 0. The result text never classifies (it can carry
    what the agent read in the app or the reviewer notes); once a field
    has, its "hit your weekly limit · resets ..." names the limit."""
    if result is None:
        return None
    error = result.get("error") if isinstance(result.get("error"), dict) else {}
    usage = result.get("usage") if isinstance(result.get("usage"), dict) else {}
    shown = []
    for field, status in (("api_error_status", result.get("api_error_status")), ("error.status", error.get("status"))):
        status = count(status)
        if status is not None and (status in (429, 529) or 500 <= status < 600):
            shown.append(f"{field}={status}")
    for field, kind in (("api_error_type", result.get("api_error_type")), ("error.type", error.get("type")),
                        ("error", result.get("error"))):
        if isinstance(kind, str) and kind in UNSERVED_ERROR_TYPES:
            shown.append(f"{field}={kind}")
    api_error = result.get("api_error") if isinstance(result.get("api_error"), str) else None
    usage_limit = api_error in USAGE_LIMIT_ERRORS
    if usage_limit:
        shown.append(f"api_error={api_error}")
    api_ms, tokens = count(result.get("duration_api_ms")), count(usage.get("input_tokens"))
    if api_ms == 0 and tokens == 0:
        shown.append("duration_api_ms=0, usage.input_tokens=0")
    if not shown:
        return None
    limit = resets = None
    text = result.get("result")
    if result.get("is_error") is True and isinstance(text, str) and (said := USAGE_LIMIT_TEXT.search(text)):
        usage_limit, limit, resets = True, said["limit"].lower(), said["resets"]
    api_type = result.get("api_error_type")
    return {"message": API_UNAVAILABLE_MESSAGE, "fields": ", ".join(shown), "duration_api_ms": api_ms,
            "input_tokens": tokens, "api_error_status": count(result.get("api_error_status")),
            "api_error_type": api_type if isinstance(api_type, str) else None, "api_error": api_error,
            "usage_limit": usage_limit, "limit": limit, "resets": resets}


def retry_backoff() -> float:
    try:
        base = max(0.0, float(os.environ.get(RETRY_BACKOFF_ENV, DEFAULT_RETRY_BACKOFF_S)))
    except ValueError:
        base = DEFAULT_RETRY_BACKOFF_S
    return base + random.uniform(0, base / 2)


def read_verdict(findings: Path) -> list | None:
    try:
        items = json.loads(findings.read_text())
        assert isinstance(items, list)
    except (OSError, json.JSONDecodeError, AssertionError):
        return None
    return items


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
    review_env = dict(os.environ)
    review_env.update({f"SIMCTL_CHILD_{key}": value for key, value in REVIEW_ENV.items()})
    first_launch_env = dict(review_env)
    first_launch_env.update({f"SIMCTL_CHILD_{key}": value for key, value in FIRST_LAUNCH_ENV.items()})
    subprocess.run(["xcrun", "simctl", "launch", args.udid, bid, *REVIEW_LAUNCH_ARGS], check=False, env=first_launch_env)

    prompt = PROMPT.format(udid=args.udid, bundle_id=bid, out=out, findings=findings,
                           launch_args=shlex.join(REVIEW_LAUNCH_ARGS), code=MOCK_EMAIL_CODE,
                           setup=setup_text(Path(args.setup)))
    deadline = time.monotonic() + AGENT_BUDGET_S
    for attempt in (1, 2):
        # A findings file left from an earlier run is never this run's verdict.
        findings.unlink(missing_ok=True)
        try:
            proc = subprocess.run(
                ["claude", "-p", prompt,
                 "--allowedTools", "Bash(axe:*)", "Bash(xcrun simctl:*)", "Read", "Write",
                 "--max-turns", args.max_turns, "--output-format", "json"],
                capture_output=True, text=True, timeout=max(1.0, deadline - time.monotonic()), cwd=out,
                env=review_env,
            )
        except subprocess.TimeoutExpired as timeout:
            for name, text in (("transcript.json", timeout.stdout), ("stderr.txt", timeout.stderr)):
                (out / name).write_text(text.decode(errors="replace") if isinstance(text, bytes) else (text or ""))
            return unjudged(findings, "agent.no-verdict", "the agent ran past 45 minutes with no verdict", str(out))
        (out / "transcript.json").write_text(proc.stdout or "")
        (out / "stderr.txt").write_text(proc.stderr or "")
        items = read_verdict(findings)
        # Read from the CLI's result only, and only when nothing was judged:
        # a verdict on either attempt counts as it always has.
        unserved = api_unavailable(cli_result(proc.stdout or "")) if items is None else None
        if unserved is None:
            break
        unserved["attempts"] = attempt
        if unserved["usage_limit"]:
            # Gate run 43637095919 (job 132576237860): the account's weekly
            # limit, which no retry in this run can clear.
            limit = f"{unserved['limit'] or 'usage'} limit"
            resets = f", resets {unserved['resets']}" if unserved["resets"] else ""
            return unjudged(findings, "agent.api-unavailable",
                            f"{API_UNAVAILABLE_MESSAGE}: {limit}{resets}; the CLI result showed {unserved['fields']};"
                            " not retried, since a usage limit does not clear in a minute", str(out), unserved)
        if attempt == 1:
            # Gate run 43621274696 (job 132527403700): about 2 s, no API time,
            # no tokens, the shared account rate limited.
            backoff = retry_backoff()
            # Attempt 1's screenshots go aside too, so the retry's verdict
            # stands on its own walk (the no-walk check counts step-*.png).
            for path in [out / "transcript.json", out / "stderr.txt", *out.glob("step-*.png")]:
                path.replace(out / f"attempt-1-{path.name}")
            if time.monotonic() + backoff >= deadline:
                break
            print(f"::warning::agent reviewer pass: the API did not serve the run ({unserved['fields']}); "
                  f"retrying once in {backoff:.0f} s", file=sys.stderr)
            time.sleep(backoff)
            continue
        return unjudged(findings, "agent.api-unavailable",
                        f"{API_UNAVAILABLE_MESSAGE}: the CLI result showed {unserved['fields']} on both attempts;"
                        " nothing was judged, so rerun the gate once the account recovers", str(out), unserved)
    if unserved is not None:
        return unjudged(findings, "agent.api-unavailable",
                        f"{API_UNAVAILABLE_MESSAGE}: the CLI result showed {unserved['fields']}, with no time left to"
                        " retry; nothing was judged, so rerun the gate once the account recovers", str(out), unserved)
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
