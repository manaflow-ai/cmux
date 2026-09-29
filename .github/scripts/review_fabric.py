#!/usr/bin/env python3
"""Evaluate provider-neutral review receipts for one exact pull-request head."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

RECEIPT_SCHEMA = "cmux.review-fabric/v1"
POLICY_SCHEMA = "cmux.review-fabric-policy/v1"
EVALUATION_SCHEMA = "cmux.review-fabric-evaluation/v1"

RUN_STATUSES = {"queued", "running", "completed", "failed", "cancelled", "unavailable"}
RUN_DISPOSITIONS = {"accept", "repair", "hold", "execute", "reject", "unavailable"}
FINDING_DISPOSITIONS = {
    "pending",
    "fixed",
    "declined_with_rationale",
    "not_actionable",
    "answered_unverified",
    "resolved_unverified",
    "resolved_unanswered",
    "outdated",
    "unavailable",
    "waiting_on_reviewer",
    "blocked_on_human",
}
SEVERITIES = {"P0", "P1", "P2", "P3", "info", "unknown"}
COMMIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
EVIDENCE_CLASSES = {
    "source-read",
    "model-executed",
    "target-test-prepared",
    "target-executed",
    "integration-executed",
    "full-gate",
}


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def _required_string(item: dict[str, Any], key: str, kind: str, errors: list[str]) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{kind} requires non-empty {key}")
        return ""
    return value


def validate_document(document: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if document.get("schema") != RECEIPT_SCHEMA:
        errors.append(f"receipt schema must be {RECEIPT_SCHEMA}")
    if policy.get("schema") != POLICY_SCHEMA:
        errors.append(f"policy schema must be {POLICY_SCHEMA}")

    head = _required_string(document, "head_sha", "receipt", errors)
    if head and COMMIT_SHA_RE.fullmatch(head) is None:
        errors.append("receipt head_sha must be a full lowercase 40-hex commit SHA")
    if document.get("capture_complete") is not True:
        errors.append("review receipt capture is incomplete")

    runs = document.get("runs")
    if not isinstance(runs, list):
        errors.append("receipt runs must be a list")
        runs = []
    findings = document.get("findings")
    if not isinstance(findings, list):
        errors.append("receipt findings must be a list")
        findings = []

    run_ids: set[str] = set()
    for index, run in enumerate(runs):
        if not isinstance(run, dict):
            errors.append(f"run[{index}] must be an object")
            continue
        run_id = _required_string(run, "id", f"run[{index}]", errors)
        if run_id in run_ids:
            errors.append(f"duplicate review run id: {run_id}")
        run_ids.add(run_id)
        for key in (
            "worker_id",
            "session_id",
            "provider",
            "harness",
            "model",
            "role",
            "capability_class",
            "head_sha",
            "status",
            "disposition",
            "rules_version",
        ):
            _required_string(run, key, f"run {run_id or index}", errors)
        run_head = run.get("head_sha")
        if isinstance(run_head, str) and run_head.strip() and COMMIT_SHA_RE.fullmatch(run_head) is None:
            errors.append(f"run {run_id or index} head_sha must be a full lowercase 40-hex commit SHA")
        if run.get("status") not in RUN_STATUSES:
            errors.append(f"run {run_id or index} has unknown status {run.get('status')!r}")
        if run.get("disposition") not in RUN_DISPOSITIONS:
            errors.append(f"run {run_id or index} has unknown disposition {run.get('disposition')!r}")
        evidence_class = run.get("evidence_class")
        if evidence_class is not None and evidence_class not in EVIDENCE_CLASSES:
            errors.append(f"run {run_id or index} has unknown evidence_class {evidence_class!r}")

    finding_ids: set[str] = set()
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            errors.append(f"finding[{index}] must be an object")
            continue
        finding_id = _required_string(finding, "id", f"finding[{index}]", errors)
        if finding_id in finding_ids:
            errors.append(f"duplicate finding id: {finding_id}")
        finding_ids.add(finding_id)
        run_id = _required_string(finding, "run_id", f"finding {finding_id or index}", errors)
        if run_id and run_id not in run_ids:
            errors.append(f"finding {finding_id or index} references unknown run {run_id}")
        finding_head = _required_string(finding, "head_sha", f"finding {finding_id or index}", errors)
        if finding_head and COMMIT_SHA_RE.fullmatch(finding_head) is None:
            errors.append(
                f"finding {finding_id or index} head_sha must be a full lowercase 40-hex commit SHA"
            )
        if finding.get("severity") not in SEVERITIES:
            errors.append(f"finding {finding_id or index} has unknown severity {finding.get('severity')!r}")
        if finding.get("disposition") not in FINDING_DISPOSITIONS:
            errors.append(
                f"finding {finding_id or index} has unknown disposition {finding.get('disposition')!r}"
            )
        if not isinstance(finding.get("actionable"), bool):
            errors.append(f"finding {finding_id or index} requires boolean actionable")
        if not isinstance(finding.get("published"), bool):
            errors.append(f"finding {finding_id or index} requires boolean published")
        if not isinstance(finding.get("verified"), bool):
            errors.append(f"finding {finding_id or index} requires boolean verified")

    minimum = policy.get("minimum_independent_runs")
    if not isinstance(minimum, int) or minimum < 1:
        errors.append("policy minimum_independent_runs must be a positive integer")
    quorum_roles = policy.get("quorum_roles")
    if not isinstance(quorum_roles, list) or not quorum_roles or not all(
        isinstance(role, str) and role for role in quorum_roles
    ):
        errors.append("policy quorum_roles must be a non-empty string list")
    required_classes = policy.get("required_capability_classes")
    if not isinstance(required_classes, dict) or not all(
        isinstance(name, str)
        and name
        and isinstance(count, int)
        and count >= 0
        for name, count in (required_classes or {}).items()
    ):
        errors.append("policy required_capability_classes must map names to non-negative integers")
    blocking_dispositions = policy.get("blocking_run_dispositions")
    if not isinstance(blocking_dispositions, list) or not all(
        disposition in RUN_DISPOSITIONS for disposition in (blocking_dispositions or [])
    ):
        errors.append("policy blocking_run_dispositions contains an unknown disposition")
    satisfied = policy.get("satisfied_finding_dispositions")
    if not isinstance(satisfied, list) or not all(
        disposition in FINDING_DISPOSITIONS for disposition in (satisfied or [])
    ):
        errors.append("policy satisfied_finding_dispositions contains an unknown disposition")
    blocking_severities = policy.get("blocking_severities")
    if not isinstance(blocking_severities, list) or not all(
        severity in SEVERITIES for severity in (blocking_severities or [])
    ):
        errors.append("policy blocking_severities contains an unknown severity")
    return errors


def evaluate(document: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    validation_errors = validate_document(document, policy)
    head = str(document.get("head_sha") or "")
    reasons = list(validation_errors)

    runs = document.get("runs") if isinstance(document.get("runs"), list) else []
    current_runs = [
        run
        for run in runs
        if isinstance(run, dict) and run.get("head_sha") == head
    ]
    stale_run_ids = [
        str(run.get("id") or "")
        for run in runs
        if isinstance(run, dict) and run.get("head_sha") != head
    ]

    blocking_run_dispositions = set(policy.get("blocking_run_dispositions") or [])
    quorum_roles = set(policy.get("quorum_roles") or [])
    blocked_runs = [
        run
        for run in current_runs
        if run.get("status") == "completed"
        and run.get("disposition") in blocking_run_dispositions
    ]
    for run in blocked_runs:
        reasons.append(
            f"review run {run.get('id')} ended with blocking disposition {run.get('disposition')}"
        )

    eligible_runs = [
        run
        for run in current_runs
        if run.get("status") == "completed"
        and run.get("role") in quorum_roles
        and run.get("disposition") not in blocking_run_dispositions
        and run.get("disposition") != "unavailable"
    ]

    # One worker/session gets one quorum vote even if it invokes several
    # providers/models. Capability coverage is also session-scoped: a session
    # that actually ran a frontier reviewer remains frontier-capable regardless
    # of the order in which its other runs appear in the receipt.
    session_capabilities: dict[str, set[str]] = {}
    for run in eligible_runs:
        session_id = str(run.get("session_id") or "")
        capability = str(run.get("capability_class") or "")
        if session_id:
            session_capabilities.setdefault(session_id, set()).add(capability)

    minimum = int(policy.get("minimum_independent_runs") or 0)
    if len(session_capabilities) < minimum:
        reasons.append(
            f"independent review quorum is {len(session_capabilities)}/{minimum} for head {head}"
        )

    capability_counts = Counter(
        capability
        for capabilities in session_capabilities.values()
        for capability in capabilities
    )
    for capability, required in (policy.get("required_capability_classes") or {}).items():
        have = capability_counts.get(capability, 0)
        if have < required:
            reasons.append(
                f"capability quorum {capability} is {have}/{required}"
            )

    satisfied_dispositions = set(policy.get("satisfied_finding_dispositions") or [])
    blocking_severities = set(policy.get("blocking_severities") or [])
    findings = document.get("findings") if isinstance(document.get("findings"), list) else []
    current_findings = [
        finding
        for finding in findings
        if isinstance(finding, dict) and finding.get("head_sha") == head
    ]

    active_findings = []
    for finding in current_findings:
        if not finding.get("published") or not finding.get("actionable"):
            continue
        active_findings.append(finding)
        finding_id = finding.get("id")
        disposition = finding.get("disposition")
        if (
            finding.get("verified") is True
            and finding.get("severity") in blocking_severities
            and disposition not in satisfied_dispositions
        ):
            reasons.append(
                f"verified blocker {finding_id} remains {disposition}"
            )
        if disposition not in satisfied_dispositions:
            reasons.append(
                f"actionable finding {finding_id} remains {disposition}"
            )
            continue

        if disposition == "declined_with_rationale" and not str(
            finding.get("rationale") or ""
        ).strip():
            reasons.append(
                f"declined finding {finding_id} requires a rationale"
            )

        latest_reviewer = parse_time(finding.get("latest_reviewer_at"))
        latest_reply = parse_time(finding.get("latest_reply_at"))
        if latest_reviewer is None or latest_reply is None or latest_reply <= latest_reviewer:
            reasons.append(
                f"finding {finding_id} lacks a reply after the latest reviewer message"
            )

    # Keep reasons stable for machine consumers and readable logs.
    unique_reasons = list(dict.fromkeys(reasons))
    report = {
        "schema": EVALUATION_SCHEMA,
        "head_sha": head,
        "passed": not unique_reasons,
        "capture_complete": document.get("capture_complete") is True,
        "counts": {
            "current_runs": len(current_runs),
            "eligible_runs": len(eligible_runs),
            "independent_sessions": len(session_capabilities),
            "current_findings": len(current_findings),
            "actionable_published_findings": len(active_findings),
        },
        "capability_counts": dict(sorted(capability_counts.items())),
        "stale_run_ids": stale_run_ids,
        "reasons": unique_reasons,
    }
    return report


def load_json(path: str) -> dict[str, Any]:
    if path == "-":
        value = json.load(sys.stdin)
    else:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("JSON document must be an object")
    return value


def default_policy_path() -> Path:
    return Path(__file__).resolve().parents[1] / "review-fabric-policy.json"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="-", help="review receipt JSON path, or - for stdin")
    parser.add_argument(
        "--policy",
        default=str(default_policy_path()),
        help="review fabric policy JSON path",
    )
    parser.add_argument("--json", action="store_true", help="emit the full evaluation JSON")
    args = parser.parse_args()

    try:
        report = evaluate(load_json(args.input), load_json(args.policy))
    except Exception as error:
        print(f"review-fabric: ERROR: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print("review-fabric: " + ("PASS" if report["passed"] else "FAIL"))
        print(
            "- independent sessions: "
            f"{report['counts']['independent_sessions']}"
        )
        for reason in report["reasons"]:
            print(f"- {reason}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
