#!/usr/bin/env python3
"""Read and optionally gate the review obligations for an opted-in agent PR."""
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
INFO_PREFIXES = ("review limit reached", "review in progress")
UNAVAILABLE_PREFIXES = INFO_PREFIXES + ("bugbot is paused",)


def parse_time(value: str | None) -> dt.datetime:
    if not value:
        return dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def login(value: dict[str, Any] | None) -> str:
    return str((value or {}).get("login") or "").lower()


def is_review_bot(name: str, bots: tuple[str, ...]) -> bool:
    return any(name == bot or name.startswith(bot + "[") for bot in bots)


def normalized_body(body: str) -> str:
    text = re.sub(r"<[^>]+>", " ", body)
    return re.sub(r"\s+", " ", text).strip().lower()


def comment_kind(body: str) -> str:
    """Return a stable provider-format classification, never a substring guess."""
    text = normalized_body(body)
    raw = re.sub(r"\s+", " ", body).strip().lower()
    if "<!-- greptile_summary -->" in raw or "<!-- this is an auto-generated comment: summarize by coderabbit.ai -->" in raw:
        return "summary"
    if text.startswith(UNAVAILABLE_PREFIXES):
        return "unavailable"
    return "finding"


def is_informational(body: str) -> bool:
    # Only recognize stable provider formats. Do not discard an actionable
    # request merely because it happens to mention rate limiting or a walkthrough.
    return comment_kind(body) != "finding"


@dataclass(frozen=True)
class Obligation:
    thread_id: str
    bot: str
    path: str
    line: int | None
    latest_bot_comment_at: str
    replied: bool
    resolved: bool
    active: bool = True
    outdated: bool = False
    kind: str = "finding"
    latest_reply_at: str | None = None
    reply_actor: str | None = None
    disposition: str = "pending_reply"


def configured_reply_actors(pr: dict[str, Any]) -> tuple[str, ...]:
    configured = tuple(
        actor.strip().lower()
        for actor in os.environ.get("AGENT_REVIEW_REPLY_ACTORS", "").split(",")
        if actor.strip()
    )
    return configured or (login(pr.get("author")),)


def canonical_bot(name: str, bots: tuple[str, ...]) -> str | None:
    for bot in bots:
        if is_review_bot(name, (bot,)):
            return bot
    return None


def review_ledger(
    pr: dict[str, Any],
    bots: tuple[str, ...],
    reply_actors: tuple[str, ...],
) -> list[Obligation]:
    """Build a read-only ledger; inactive records remain available for audit."""
    result: list[Obligation] = []
    for thread in (pr.get("reviewThreads") or {}).get("nodes") or []:
        comments = (thread.get("comments") or {}).get("nodes") or []
        if not comments:
            continue
        first = comments[0]
        bot = canonical_bot(login(first.get("author")), bots)
        if bot is None:
            continue
        kind = comment_kind(first.get("body") or "")
        outdated = bool(thread.get("isOutdated"))
        resolved = bool(thread.get("isResolved"))
        bot_comments = [c for c in comments if canonical_bot(login(c.get("author")), bots) == bot]
        latest_bot = max(bot_comments, key=lambda c: parse_time(c.get("createdAt")))
        latest_bot_time = parse_time(latest_bot.get("createdAt"))
        replies = [
            c for c in comments
            if login(c.get("author")) in reply_actors
            and parse_time(c.get("createdAt")) > latest_bot_time
        ]
        latest_reply = max(replies, key=lambda c: parse_time(c.get("createdAt"))) if replies else None
        replied = latest_reply is not None
        if outdated:
            disposition = "outdated"
        elif kind == "summary":
            disposition = "informational"
        elif kind == "unavailable":
            disposition = "unavailable"
        elif replied and resolved:
            disposition = "resolved_unverified"
        elif replied:
            disposition = "answered_unverified"
        elif resolved:
            disposition = "resolved_unanswered"
        else:
            disposition = "pending_reply"
        result.append(Obligation(
            thread_id=str(thread.get("id") or ""),
            bot=bot,
            path=str(thread.get("path") or ""),
            line=thread.get("line"),
            latest_bot_comment_at=str(latest_bot.get("createdAt") or ""),
            replied=replied,
            resolved=resolved,
            active=kind == "finding" and not outdated,
            outdated=outdated,
            kind=kind,
            latest_reply_at=str(latest_reply.get("createdAt")) if latest_reply else None,
            reply_actor=login(latest_reply.get("author")) if latest_reply else None,
            disposition=disposition,
        ))
    return result


def obligations(pr: dict[str, Any], bots: tuple[str, ...], reply_actors: tuple[str, ...] | None = None) -> list[Obligation]:
    actors = reply_actors or configured_reply_actors(pr)
    return [item for item in review_ledger(pr, bots, actors) if item.active]


def evaluate(
    pr: dict[str, Any],
    *,
    required_bots: tuple[str, ...] = DEFAULT_REVIEW_BOTS,
    reply_actors: tuple[str, ...] | None = None,
) -> tuple[bool, list[str], list[Obligation]]:
    if OPT_IN_MARKER not in str(pr.get("body") or ""):
        return True, ["PR is not opted into the agent review gate"], []
    head = str(pr.get("headRefOid") or "")
    reviews = (pr.get("reviews") or {}).get("nodes") or []
    current_reviews = {
        bot
        for r in reviews
        if (r.get("commit") or {}).get("oid") == head
        and r.get("state") in {"COMMENTED", "APPROVED", "CHANGES_REQUESTED"}
        for bot in [canonical_bot(login(r.get("author")), required_bots)]
        if bot is not None
    }
    require_coverage = os.environ.get("REQUIRE_BOT_REVIEW_COVERAGE") == "1"
    missing = [bot for bot in required_bots if bot not in current_reviews] if require_coverage else []
    actors = reply_actors or configured_reply_actors(pr)
    ledger = review_ledger(pr, required_bots, actors)
    items = [item for item in ledger if item.active]
    unanswered = [item for item in items if not item.replied]
    reasons: list[str] = []
    if pr.get("captureComplete") is False:
        reasons.append("review data capture incomplete; current-head obligations are unknown")
    if missing:
        reasons.append("review pending for current head: " + ", ".join(missing))
    if unanswered:
        reasons.extend(
            f"unanswered {item.bot} thread {item.thread_id} ({item.path}:{item.line or '?'})"
            for item in unanswered
        )
    if not reasons:
        reasons.append(
            f"current head has configured actor replies for {len(items)} actionable bot thread(s) answered; "
            "a reply does not prove the finding was fixed"
        )
    capture_incomplete = pr.get("captureComplete") is False
    return not capture_incomplete and not missing and not unanswered, reasons, items


def fetch_pr() -> dict[str, Any]:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.load(open(event_path, encoding="utf-8")) if event_path else {}
    payload = event.get("pull_request") or {}
    number = payload.get("number") or event.get("number")
    repository = os.environ.get("GITHUB_REPOSITORY", "").split("/", 1)
    if len(repository) != 2 or not number:
        raise RuntimeError("GITHUB_REPOSITORY and pull_request.number are required")
    def graphql(query: str, variables: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps({"query": query, "variables": variables}).encode()
        request = urllib.request.Request(
            "https://api.github.com/graphql", data=data,
            headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request) as response:
            payload = json.load(response)
        if payload.get("errors"):
            raise RuntimeError("GitHub review data request failed")
        return payload["data"]

    variables = {"owner": repository[0], "repo": repository[1], "number": int(number), "reviewsAfter": None, "threadsAfter": None}
    base_query = """query($owner:String!, $repo:String!, $number:Int!, $reviewsAfter:String, $threadsAfter:String) {
      repository(owner:$owner,name:$repo) { pullRequest(number:$number) {
        number body headRefOid author { login }
        reviews(first:100, after:$reviewsAfter) { nodes { author { login } state submittedAt commit { oid } } pageInfo { hasNextPage endCursor } }
        reviewThreads(first:100, after:$threadsAfter) { nodes { id isResolved isOutdated path line comments(first:100) { nodes { author { login } body createdAt } pageInfo { hasNextPage endCursor } } } pageInfo { hasNextPage endCursor } }
      } }
    }"""
    first = graphql(base_query, variables)["repository"]["pullRequest"]
    reviews = list(first["reviews"]["nodes"])
    threads = list(first["reviewThreads"]["nodes"])
    for connection in ("reviews", "reviewThreads"):
        page = first[connection]["pageInfo"]
        while page["hasNextPage"]:
            variables["reviewsAfter" if connection == "reviews" else "threadsAfter"] = page["endCursor"]
            next_pr = graphql(base_query, variables)["repository"]["pullRequest"]
            target = reviews if connection == "reviews" else threads
            target.extend(next_pr[connection]["nodes"])
            page = next_pr[connection]["pageInfo"]
    # Paginate comments independently; the nested connection shares the thread
    # cursor in the PR query, so a node query avoids silently dropping comment 101+.
    comment_query = """query($id:ID!, $after:String) { node(id:$id) { ... on PullRequestReviewThread {
      comments(first:100, after:$after) { nodes { author { login } body createdAt } pageInfo { hasNextPage endCursor } }
    } } }"""
    for thread in threads:
        comments = thread["comments"]["nodes"]
        page = thread["comments"]["pageInfo"]
        while page["hasNextPage"]:
            result = graphql(comment_query, {"id": thread["id"], "after": page["endCursor"]})["node"]["comments"]
            comments.extend(result["nodes"])
            page = result["pageInfo"]
        thread["comments"]["nodes"] = comments
    first["reviews"]["nodes"] = reviews
    first["reviewThreads"]["nodes"] = threads
    first["captureComplete"] = True
    return first


def ledger_report(pr: dict[str, Any], bots: tuple[str, ...], actors: tuple[str, ...]) -> dict[str, Any]:
    items = review_ledger(pr, bots, actors)
    reviews = (pr.get("reviews") or {}).get("nodes") or []
    head = str(pr.get("headRefOid") or "")
    coverage = []
    for bot in bots:
        reviewed = any(
            canonical_bot(login(review.get("author")), bots) == bot
            and (review.get("commit") or {}).get("oid") == head
            and review.get("state") in {"COMMENTED", "APPROVED", "CHANGES_REQUESTED"}
            for review in reviews
        )
        unavailable = any(item.bot == bot and item.kind == "unavailable" for item in items)
        coverage.append({"bot": bot, "status": "reviewed" if reviewed else "unavailable" if unavailable else "pending"})
    return {
        "schema": "cmux.agent-pr-review/v1",
        "pr_number": pr.get("number"),
        "head_sha": head,
        "capture_complete": pr.get("captureComplete", True),
        "configured_review_bots": list(bots),
        "configured_reply_actors": list(actors),
        "coverage": coverage,
        "obligations": [
            {
                "thread_id": item.thread_id,
                "bot": item.bot,
                "path": item.path,
                "line": item.line,
                "kind": item.kind,
                "active": item.active,
                "outdated": item.outdated,
                "resolved": item.resolved,
                "latest_bot_comment_at": item.latest_bot_comment_at,
                "latest_reply_at": item.latest_reply_at,
                "reply_actor": item.reply_actor,
                "disposition": item.disposition,
            }
            for item in items
        ],
    }


def main() -> int:
    try:
        pr = fetch_pr()
        bots = tuple(
            bot.strip().lower()
            for bot in os.environ.get("REVIEW_BOTS", ",".join(DEFAULT_REVIEW_BOTS)).split(",")
            if bot.strip()
        )
        actors = configured_reply_actors(pr)
        passed, reasons, items = evaluate(pr, required_bots=bots, reply_actors=actors)
        if "--json" in sys.argv[1:]:
            print(json.dumps(ledger_report(pr, bots, actors), indent=2, sort_keys=True))
            return 0 if passed else 1
        print("agent-pr-review-complete: " + ("PASS" if passed else "FAIL"))
        if passed:
            print("- all current actionable review threads have configured actor responses")
        else:
            if any(reason.startswith("review pending") for reason in reasons):
                print("- review from a configured provider is pending")
            if any(reason.startswith("unanswered") for reason in reasons):
                print("- an actionable review thread is unanswered")
        print(f"- actionable current threads: {len(items)}")
        return 0 if passed else 1
    except Exception:
        print("agent-pr-review-complete: ERROR: unable to read GitHub review data", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
