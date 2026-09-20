#!/usr/bin/env python3
"""Gate opted-in agent PRs on current, answered review-bot findings."""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass
from typing import Any

OPT_IN_MARKER = "<!-- agent-pr-review-required -->"
DEFAULT_REVIEW_BOTS = ("coderabbitai", "greptile-apps")
INFO_MARKERS = ("rate limit", "review limit reached", "walkthrough", "no actionable")


def parse_time(value: str | None) -> dt.datetime:
    if not value:
        return dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def login(value: dict[str, Any] | None) -> str:
    return str((value or {}).get("login") or "").lower()


def is_review_bot(name: str, bots: tuple[str, ...]) -> bool:
    return any(name == bot or name.startswith(bot + "[") for bot in bots)


def is_informational(body: str) -> bool:
    text = re.sub(r"\s+", " ", body).strip().lower()
    return any(marker in text for marker in INFO_MARKERS)


@dataclass(frozen=True)
class Obligation:
    thread_id: str
    bot: str
    path: str
    line: int | None
    latest_bot_comment_at: str
    replied: bool
    resolved: bool


def obligations(pr: dict[str, Any], bots: tuple[str, ...]) -> list[Obligation]:
    pr_author = login(pr.get("author"))
    result: list[Obligation] = []
    for thread in (pr.get("reviewThreads") or {}).get("nodes") or []:
        if thread.get("isOutdated"):
            continue
        comments = (thread.get("comments") or {}).get("nodes") or []
        if not comments:
            continue
        first = comments[0]
        bot = login(first.get("author"))
        if not is_review_bot(bot, bots) or is_informational(first.get("body") or ""):
            continue
        bot_comments = [c for c in comments if is_review_bot(login(c.get("author")), bots)]
        latest_bot = max(bot_comments, key=lambda c: parse_time(c.get("createdAt")))
        latest_bot_time = parse_time(latest_bot.get("createdAt"))
        replied = any(
            login(c.get("author")) == pr_author
            and parse_time(c.get("createdAt")) > latest_bot_time
            for c in comments
        )
        result.append(Obligation(
            thread_id=str(thread.get("id") or ""),
            bot=bot,
            path=str(thread.get("path") or ""),
            line=thread.get("line"),
            latest_bot_comment_at=str(latest_bot.get("createdAt") or ""),
            replied=replied,
            resolved=bool(thread.get("isResolved")),
        ))
    return result


def evaluate(
    pr: dict[str, Any],
    *,
    required_bots: tuple[str, ...] = DEFAULT_REVIEW_BOTS,
) -> tuple[bool, list[str], list[Obligation]]:
    if OPT_IN_MARKER not in str(pr.get("body") or ""):
        return True, ["PR is not opted into the agent review gate"], []
    head = str(pr.get("headRefOid") or "")
    reviews = (pr.get("reviews") or {}).get("nodes") or []
    current_reviews = {
        login(r.get("author"))
        for r in reviews
        if (r.get("commit") or {}).get("oid") == head and r.get("state") in {"COMMENTED", "APPROVED", "CHANGES_REQUESTED"}
    }
    require_coverage = os.environ.get("REQUIRE_BOT_REVIEW_COVERAGE") == "1"
    missing = [bot for bot in required_bots if bot not in current_reviews] if require_coverage else []
    items = obligations(pr, required_bots)
    unanswered = [item for item in items if not item.replied]
    reasons: list[str] = []
    if missing:
        reasons.append("review pending for current head: " + ", ".join(missing))
    if unanswered:
        reasons.extend(
            f"unanswered {item.bot} thread {item.thread_id} ({item.path}:{item.line or '?'})"
            for item in unanswered
        )
    if not reasons:
        reasons.append(f"current head reviewed; {len(items)} actionable bot thread(s) answered")
    return not missing and not unanswered, reasons, items


def fetch_pr() -> dict[str, Any]:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.load(open(event_path, encoding="utf-8")) if event_path else {}
    payload = event.get("pull_request") or {}
    number = payload.get("number") or event.get("number")
    repository = os.environ.get("GITHUB_REPOSITORY", "").split("/", 1)
    if len(repository) != 2 or not number:
        raise RuntimeError("GITHUB_REPOSITORY and pull_request.number are required")
    query = """query($owner:String!, $repo:String!, $number:Int!) { repository(owner:$owner,name:$repo) { pullRequest(number:$number) { body headRefOid author { login } reviews(first:100) { nodes { author { login } state submittedAt commit { oid } } } reviewThreads(first:100) { nodes { id isResolved isOutdated path line comments(first:100) { nodes { author { login } body createdAt } } } } } } }"""
    data = json.dumps({"query": query, "variables": {"owner": repository[0], "repo": repository[1], "number": int(number)}}).encode()
    request = urllib.request.Request(
        "https://api.github.com/graphql", data=data,
        headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    if payload.get("errors"):
        raise RuntimeError(json.dumps(payload["errors"]))
    return payload["data"]["repository"]["pullRequest"]


def main() -> int:
    try:
        pr = fetch_pr()
        bots = tuple(filter(None, (os.environ.get("REVIEW_BOTS", ",".join(DEFAULT_REVIEW_BOTS)).split(","))))
        passed, reasons, items = evaluate(pr, required_bots=bots)
        print("agent-pr-review-complete: " + ("PASS" if passed else "FAIL"))
        for reason in reasons:
            print("- " + reason)
        print(f"- head: {pr.get('headRefOid', '?')}")
        print(f"- actionable current threads: {len(items)}")
        return 0 if passed else 1
    except Exception as error:
        print(f"agent-pr-review-complete: ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
