#!/usr/bin/env python3
"""Request automated review and optionally gate review obligations for a PR."""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

OPT_IN_MARKER = "<!-- agent-pr-review-required -->"
DEFAULT_REVIEW_BOTS = ("coderabbitai", "greptile-apps")
INFO_PREFIXES = ("review limit reached", "review in progress")
UNAVAILABLE_PREFIXES = INFO_PREFIXES + ("bugbot is paused",)
GREPTILE_SUMMARY_MARKER = "<!-- greptile_summary -->"
GREPTILE_REQUEST_MARKER = "<!-- cmux-greptile-review-request:{head} -->"
GREPTILE_TRIGGER = "@greptile review"


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
    if (
        "<!-- greptile_summary -->" in raw
        or "<!-- this is an auto-generated comment: summarize by coderabbit.ai -->" in raw
        or "<!-- walkthrough_start -->" in raw
    ):
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


def configured_coverage_bots(required_bots: tuple[str, ...]) -> tuple[str, ...]:
    """Return the configured providers whose review must match the current head."""
    configured = tuple(
        bot.strip().lower()
        for bot in os.environ.get("REQUIRED_REVIEW_COVERAGE_BOTS", "").split(",")
        if bot.strip()
    )
    if configured:
        unknown = [bot for bot in configured if bot not in required_bots]
        if unknown:
            raise RuntimeError(
                "required review coverage bot is absent from REVIEW_BOTS: "
                + ", ".join(unknown)
            )
        return configured
    if os.environ.get("REQUIRE_BOT_REVIEW_COVERAGE") == "1":
        return required_bots
    return ()


def greptile_summary_head(pr: dict[str, Any]) -> str | None:
    """Return the head SHA named by Greptile's newest review summary."""
    candidates = []
    for comment in (pr.get("comments") or {}).get("nodes") or []:
        if canonical_bot(login(comment.get("author")), ("greptile-apps",)) != "greptile-apps":
            continue
        body = str(comment.get("body") or "")
        if GREPTILE_SUMMARY_MARKER not in body:
            continue
        match = re.search(
            r"last reviewed commit:.*?/commit/([0-9a-f]{40})",
            body,
            flags=re.IGNORECASE | re.DOTALL,
        )
        if match:
            candidates.append((parse_time(comment.get("updatedAt") or comment.get("createdAt")), match.group(1)))
    return max(candidates)[1] if candidates else None


def bot_reviewed_current_head(pr: dict[str, Any], bot: str, bots: tuple[str, ...]) -> bool:
    """Whether a provider has review evidence tied to the exact PR head."""
    head = str(pr.get("headRefOid") or "")
    if bot == "greptile-apps" and greptile_summary_head(pr) == head:
        return True
    return any(
        canonical_bot(login(review.get("author")), bots) == bot
        and (review.get("commit") or {}).get("oid") == head
        and review.get("state") in {"COMMENTED", "APPROVED", "CHANGES_REQUESTED"}
        for review in (pr.get("reviews") or {}).get("nodes") or []
    )


def greptile_check_running(head: str) -> bool:
    """Whether Greptile already has a nonterminal check run on this commit."""
    data = github_rest("GET", f"commits/{head}/check-runs") or {}
    for check in data.get("check_runs") or []:
        identity = " ".join(
            str(value or "")
            for value in (
                check.get("name"),
                (check.get("app") or {}).get("slug"),
                (check.get("app") or {}).get("name"),
            )
        ).lower()
        if "greptile" in identity and str(check.get("status") or "") != "completed":
            return True
    return False


def request_greptile_review(pr: dict[str, Any]) -> str:
    """Post at most one trusted Greptile review request for each PR head."""
    head = str(pr.get("headRefOid") or "")
    number = int(pr.get("number") or 0)
    if not head or not number:
        raise RuntimeError("pull request number and head SHA are required")
    if bot_reviewed_current_head(pr, "greptile-apps", DEFAULT_REVIEW_BOTS):
        return "already-reviewed"

    marker = GREPTILE_REQUEST_MARKER.format(head=head)
    for comment in (pr.get("comments") or {}).get("nodes") or []:
        if (
            login(comment.get("author")) in {"github-actions", "github-actions[bot]"}
            and marker in str(comment.get("body") or "")
        ):
            return "already-requested"

    try:
        if greptile_check_running(head):
            return "already-running"
    except Exception:
        # Provider check visibility is advisory. The per-head trusted marker
        # below still prevents duplicate requests on workflow retries.
        pass

    github_rest(
        "POST",
        f"issues/{number}/comments",
        {"body": f"{marker}\n{GREPTILE_TRIGGER}"},
    )
    return "requested"


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


def attention_needed(items: list[Obligation]) -> bool:
    """Whether a PR has an actionable bot finding awaiting an author reply."""
    return any(item.active and not item.replied for item in items)


def github_rest(method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if "/" not in repository:
        raise RuntimeError("GITHUB_REPOSITORY is required")
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/{path.lstrip('/')}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    return json.loads(body) if body else None


def sync_attention_label(pr: dict[str, Any], items: list[Obligation], label_name: str) -> str:
    """Synchronize the triage label without changing review-gate semantics."""
    number = int(pr.get("number") or 0)
    if not number:
        raise RuntimeError("pull request number is required")
    encoded = urllib.parse.quote(label_name, safe="")
    try:
        github_rest("GET", f"labels/{encoded}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        try:
            github_rest("POST", "labels", {
                "name": label_name,
                "color": "D1242F",
                "description": "Actionable automated review finding needs an author reply",
            })
        except urllib.error.HTTPError as create_error:
            # Another event can race us to create the repository label.
            if create_error.code != 422:
                raise

    if attention_needed(items):
        github_rest("POST", f"issues/{number}/labels", {"labels": [label_name]})
        return "present"

    try:
        github_rest("DELETE", f"issues/{number}/labels/{encoded}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    return "absent"


def evaluate(
    pr: dict[str, Any],
    *,
    required_bots: tuple[str, ...] = DEFAULT_REVIEW_BOTS,
    reply_actors: tuple[str, ...] | None = None,
) -> tuple[bool, list[str], list[Obligation]]:
    if OPT_IN_MARKER not in str(pr.get("body") or ""):
        return True, ["PR is not opted into the agent review gate"], []
    head = str(pr.get("headRefOid") or "")
    coverage_bots = configured_coverage_bots(required_bots)
    missing = [
        bot for bot in coverage_bots
        if not bot_reviewed_current_head(pr, bot, required_bots)
    ]
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
    number = payload.get("number") or event.get("number") or (event.get("issue") or {}).get("number")
    repository = os.environ.get("GITHUB_REPOSITORY", "").split("/", 1)
    if len(repository) != 2 or not number:
        raise RuntimeError("GITHUB_REPOSITORY and pull_request.number are required")
    def graphql(query: str, variables: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps({"query": query, "variables": variables}).encode()
        request = urllib.request.Request(
            "https://api.github.com/graphql", data=data,
            headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
        if payload.get("errors"):
            raise RuntimeError("GitHub review data request failed")
        return payload["data"]

    variables = {
        "owner": repository[0],
        "repo": repository[1],
        "number": int(number),
        "reviewsAfter": None,
        "threadsAfter": None,
        "commentsAfter": None,
    }
    base_query = """query($owner:String!, $repo:String!, $number:Int!, $reviewsAfter:String, $threadsAfter:String, $commentsAfter:String) {
      repository(owner:$owner,name:$repo) { pullRequest(number:$number) {
        number body headRefOid author { login }
        reviews(first:100, after:$reviewsAfter) { nodes { author { login } state submittedAt commit { oid } } pageInfo { hasNextPage endCursor } }
        reviewThreads(first:100, after:$threadsAfter) { nodes { id isResolved isOutdated path line comments(first:100) { nodes { author { login } body createdAt } pageInfo { hasNextPage endCursor } } } pageInfo { hasNextPage endCursor } }
        comments(first:100, after:$commentsAfter) { nodes { author { login } body createdAt updatedAt } pageInfo { hasNextPage endCursor } }
      } }
    }"""
    first = graphql(base_query, variables)["repository"]["pullRequest"]
    reviews = list(first["reviews"]["nodes"])
    threads = list(first["reviewThreads"]["nodes"])
    issue_comments = list(first["comments"]["nodes"])
    connections = {
        "reviews": (reviews, "reviewsAfter"),
        "reviewThreads": (threads, "threadsAfter"),
        "comments": (issue_comments, "commentsAfter"),
    }
    for connection, (target, cursor_key) in connections.items():
        page = first[connection]["pageInfo"]
        while page["hasNextPage"]:
            variables[cursor_key] = page["endCursor"]
            next_pr = graphql(base_query, variables)["repository"]["pullRequest"]
            target.extend(next_pr[connection]["nodes"])
            page = next_pr[connection]["pageInfo"]
    # Paginate comments independently; the nested connection shares the thread
    # cursor in the PR query, so a node query avoids silently dropping comment 101+.
    comment_query = """query($id:ID!, $after:String) { node(id:$id) { ... on PullRequestReviewThread {
      comments(first:100, after:$after) { nodes { author { login } body createdAt } pageInfo { hasNextPage endCursor } }
    } } }"""
    for thread in threads:
        thread_comments = thread["comments"]["nodes"]
        page = thread["comments"]["pageInfo"]
        while page["hasNextPage"]:
            result = graphql(comment_query, {"id": thread["id"], "after": page["endCursor"]})["node"]["comments"]
            thread_comments.extend(result["nodes"])
            page = result["pageInfo"]
        thread["comments"]["nodes"] = thread_comments
    first["reviews"]["nodes"] = reviews
    first["reviewThreads"]["nodes"] = threads
    first["comments"]["nodes"] = issue_comments
    first["captureComplete"] = True
    return first


def ledger_report(pr: dict[str, Any], bots: tuple[str, ...], actors: tuple[str, ...]) -> dict[str, Any]:
    items = review_ledger(pr, bots, actors)
    head = str(pr.get("headRefOid") or "")
    coverage = []
    for bot in bots:
        reviewed = bot_reviewed_current_head(pr, bot, bots)
        unavailable = any(item.bot == bot and item.kind == "unavailable" for item in items)
        coverage.append({"bot": bot, "status": "reviewed" if reviewed else "unavailable" if unavailable else "pending"})
    return {
        "schema": "cmux.agent-pr-review/v1",
        "pr_number": pr.get("number"),
        "head_sha": head,
        "capture_complete": pr.get("captureComplete", True),
        "configured_review_bots": list(bots),
        "configured_reply_actors": list(actors),
        "required_review_coverage_bots": list(configured_coverage_bots(bots)),
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
        if "--request-greptile" in sys.argv[1:]:
            state = request_greptile_review(pr)
            print(f"agent-pr-review-greptile: {state}")
            return 0

        triage_items = obligations(pr, bots, actors)
        passed, reasons, items = evaluate(pr, required_bots=bots, reply_actors=actors)
        if "--sync-label" in sys.argv[1:]:
            label_name = os.environ.get("REVIEW_ATTENTION_LABEL", "review: needs-attention").strip()
            if label_name:
                try:
                    label_state = sync_attention_label(pr, triage_items, label_name)
                    print(f"agent-pr-review-label: {label_name} {label_state}")
                except Exception:
                    # Labeling is a triage aid. A transient write failure must not
                    # change the review gate's merge decision.
                    print("agent-pr-review-label: WARNING: unable to synchronize label", file=sys.stderr)
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
