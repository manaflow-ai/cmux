#!/usr/bin/env python3
"""Fail closed unless a release environment requires independent approval."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _fail(message: str) -> int:
    print(f"release environment policy failed: {message}", file=sys.stderr)
    return 1


def _has_reviewer(entry: object) -> bool:
    if not isinstance(entry, dict):
        return False
    if entry.get("type") not in {"User", "Team"}:
        return False
    reviewer = entry.get("reviewer")
    if not isinstance(reviewer, dict):
        return False
    for key in ("login", "slug", "name"):
        value = reviewer.get(key)
        if isinstance(value, str) and value.strip():
            return True
    return False


def validate(document: object, expected_environment: str) -> str | None:
    if not isinstance(document, dict):
        return "environment response is not an object"
    if document.get("name") != expected_environment:
        return "environment name does not match the publisher"
    if document.get("can_admins_bypass") is not False:
        return "can_admins_bypass must be false"
    branch_policy = document.get("deployment_branch_policy")
    if not isinstance(branch_policy, dict):
        return "deployment branch policy must allow protected branches only"
    if branch_policy.get("protected_branches") is not True or branch_policy.get(
        "custom_branch_policies"
    ) is not False:
        return "deployment branch policy must allow protected branches only"

    rules = document.get("protection_rules")
    if not isinstance(rules, list):
        return "required reviewer protection is missing"
    reviewer_rules = [
        rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
    ]
    if len(reviewer_rules) != 1:
        return "exactly one required reviewer protection rule is required"
    reviewer_rule = reviewer_rules[0]
    if reviewer_rule.get("prevent_self_review") is not True:
        return "prevent_self_review must be true"
    reviewers = reviewer_rule.get("reviewers")
    if not isinstance(reviewers, list) or not reviewers or not all(
        _has_reviewer(entry) for entry in reviewers
    ):
        return "required reviewer list must contain a user or team"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--environment", required=True)
    parser.add_argument("--environment-json", required=True, type=Path)
    args = parser.parse_args()

    try:
        document = json.loads(args.environment_json.read_text())
    except (OSError, json.JSONDecodeError):
        return _fail("environment response is unavailable or invalid")
    error = validate(document, args.environment)
    if error is not None:
        return _fail(error)
    print("verified independent release environment policy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
