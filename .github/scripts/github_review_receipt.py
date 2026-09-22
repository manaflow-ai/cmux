#!/usr/bin/env python3
"""Convert GitHub review-bot data into provider-neutral review-fabric receipts."""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import review_fabric

DEFAULT_RULES_VERSION = "github-review-adapter-v1"


def load_gate() -> Any:
    path = SCRIPT_DIR / "agent-pr-review-gate.py"
    spec = importlib.util.spec_from_file_location("agent_pr_review_gate_for_fabric", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load agent PR review gate")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def parse_time(value: str | None) -> dt.datetime:
    if not value:
        return dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def stable_id(prefix: str, *parts: str) -> str:
    digest = hashlib.sha256("\x00".join(parts).encode()).hexdigest()[:20]
    return f"{prefix}:{digest}"


def _review_run(
    *,
    bot: str,
    head: str,
    submitted_at: str,
    state: str,
    rules_version: str,
    harness: str = "github-review",
) -> dict[str, Any]:
    run_id = stable_id("github-review", bot, head, submitted_at, harness)
    # GitHub exposes review submissions, not the provider's internal session.
    # Conservatively give one external provider one quorum session per exact
    # head, even across re-reviews or review-vs-summary evidence.
    session_id = stable_id("github-session", bot, head)
    disposition = "repair" if state == "CHANGES_REQUESTED" else "accept"
    return {
        "id": run_id,
        "worker_id": bot,
        "session_id": session_id,
        "provider": bot,
        "harness": harness,
        "model": "external-opaque",
        "role": "reviewer",
        "capability_class": "external",
        "head_sha": head,
        "status": "completed",
        "disposition": disposition,
        "rules_version": rules_version,
        "evidence_class": "source-read",
        "submitted_at": submitted_at,
    }


def _finding_disposition(item: Any) -> str:
    mapping = {
        "pending_reply": "pending",
        "answered_unverified": "answered_unverified",
        "resolved_unverified": "resolved_unverified",
        "resolved_unanswered": "resolved_unanswered",
        "outdated": "outdated",
        "informational": "not_actionable",
        "unavailable": "unavailable",
    }
    return mapping.get(str(item.disposition), "pending")


def receipt_from_pr(
    pr: dict[str, Any],
    *,
    bots: tuple[str, ...],
    reply_actors: tuple[str, ...],
    gate: Any,
    rules_version: str = DEFAULT_RULES_VERSION,
) -> dict[str, Any]:
    head = str(pr.get("headRefOid") or "")
    if len(head) != 40:
        raise ValueError("pull request headRefOid must be a full commit SHA")

    runs: list[dict[str, Any]] = []
    review_records: list[tuple[str, dt.datetime, dict[str, Any]]] = []
    by_run_id: dict[str, dict[str, Any]] = {}
    by_review_id: dict[str, dict[str, Any]] = {}

    for review in (pr.get("reviews") or {}).get("nodes") or []:
        state = str(review.get("state") or "")
        if state not in {"COMMENTED", "APPROVED", "CHANGES_REQUESTED"}:
            continue
        bot = gate.canonical_bot(gate.login(review.get("author")), bots)
        review_head = str((review.get("commit") or {}).get("oid") or "")
        if bot is None or len(review_head) != 40:
            continue
        submitted_at = str(review.get("submittedAt") or "")
        run = _review_run(
            bot=bot,
            head=review_head,
            submitted_at=submitted_at,
            state=state,
            rules_version=rules_version,
        )
        if run["id"] not in by_run_id:
            runs.append(run)
            by_run_id[run["id"]] = run
            review_records.append((bot, parse_time(submitted_at), run))
        review_id = str(review.get("id") or "")
        if review_id:
            existing = by_review_id.get(review_id)
            if existing is not None and existing["id"] != run["id"]:
                raise ValueError("GitHub review identity maps to multiple review runs")
            by_review_id[review_id] = run

    # Greptile reuses one summary comment across re-reviews. The trusted gate
    # already extracts its exact "Last reviewed commit" identity.
    if "greptile-apps" in bots:
        summary_head = gate.greptile_summary_head(pr)
        if summary_head:
            run = _review_run(
                bot="greptile-apps",
                head=summary_head,
                submitted_at=f"summary:{summary_head}",
                state="COMMENTED",
                rules_version=rules_version,
                harness="github-summary",
            )
            if run["id"] not in by_run_id:
                runs.append(run)
                by_run_id[run["id"]] = run
                review_records.append(
                    ("greptile-apps", dt.datetime.max.replace(tzinfo=dt.timezone.utc), run)
                )

    review_records.sort(key=lambda row: row[1])
    capture_complete = pr.get("captureComplete", True) is not False
    findings: list[dict[str, Any]] = []

    thread_review_ids: dict[tuple[str, str, str], str] = {}
    for thread in (pr.get("reviewThreads") or {}).get("nodes") or []:
        thread_id = str(thread.get("id") or "")
        for comment in (thread.get("comments") or {}).get("nodes") or []:
            bot = gate.canonical_bot(gate.login(comment.get("author")), bots)
            created_at = str(comment.get("createdAt") or "")
            review_id = str((comment.get("pullRequestReview") or {}).get("id") or "")
            if thread_id and bot and created_at and review_id:
                thread_review_ids[(thread_id, created_at, bot)] = review_id

    for item in gate.review_ledger(pr, bots, reply_actors):
        parent_review_id = thread_review_ids.get(
            (item.thread_id, item.latest_bot_comment_at, item.bot)
        )
        source_run = by_review_id.get(parent_review_id or "")
        if source_run is None:
            # Inline comments belong to a concrete PullRequestReview. Refuse to
            # infer provenance from timestamps: GitHub commonly creates review
            # comments seconds before the parent review's submittedAt value.
            capture_complete = False
            continue
        if source_run.get("provider") != item.bot:
            capture_complete = False
            continue
        disposition = _finding_disposition(item)
        finding = {
            "id": f"github-thread:{item.thread_id}",
            "run_id": source_run["id"],
            "head_sha": head,
            "severity": "unknown",
            "disposition": disposition,
            "actionable": bool(item.active),
            "published": True,
            "verified": False,
            "latest_reviewer_at": item.latest_bot_comment_at,
            "latest_reply_at": item.latest_reply_at,
            "path": item.path,
            "line": item.line,
            "reply_actor": item.reply_actor,
            "source_disposition": item.disposition,
        }
        findings.append(finding)

        if item.active:
            source_run["disposition"] = "repair"

    return {
        "schema": review_fabric.RECEIPT_SCHEMA,
        "head_sha": head,
        "capture_complete": capture_complete,
        "source": "github-review-ledger",
        "pr_number": pr.get("number"),
        "runs": runs,
        "findings": findings,
    }


def main() -> int:
    gate = load_gate()
    try:
        pr = gate.fetch_pr()
        bots = tuple(
            bot.strip().lower()
            for bot in os.environ.get(
                "REVIEW_BOTS",
                ",".join(gate.DEFAULT_REVIEW_BOTS),
            ).split(",")
            if bot.strip()
        )
        actors = gate.configured_reply_actors(pr)
        receipt = receipt_from_pr(
            pr,
            bots=bots,
            reply_actors=actors,
            gate=gate,
            rules_version=os.environ.get("REVIEW_RULES_VERSION", DEFAULT_RULES_VERSION),
        )
        print(json.dumps(receipt, indent=2, sort_keys=True))
        return 0
    except Exception as error:
        print(f"github-review-receipt: ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
