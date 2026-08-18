#!/usr/bin/env python3
"""Verify the protection policy on a GitHub Actions environment."""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
from typing import Any, Mapping, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


GITHUB_API_VERSION = "2022-11-28"
GITHUB_API_URL = "https://api.github.com"
USER_AGENT = "cmux-sdk-environment-policy/1 (https://github.com/manaflow-ai/cmux)"
REPOSITORY_PATTERN = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$"
)


class EnvironmentPolicyError(RuntimeError):
    """Raised when GitHub cannot prove the required environment policy."""


def _repository_slug(repository: str) -> str:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise EnvironmentPolicyError("GitHub repository must be OWNER/REPOSITORY")
    return repository


def _environment_url(
    api_url: str,
    repository: str,
    environment: str,
) -> str:
    try:
        parsed = urlsplit(api_url)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as error:
        raise EnvironmentPolicyError("GitHub API URL is malformed") from error
    if (
        parsed.scheme.casefold() != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise EnvironmentPolicyError("GitHub API URL must use HTTPS without credentials")
    if (
        hostname.casefold() != "api.github.com"
        or port not in (None, 443)
        or parsed.path not in ("", "/")
    ):
        raise EnvironmentPolicyError(
            "GitHub API URL must use the source-controlled api.github.com endpoint"
        )
    if not environment or environment.strip() != environment:
        raise EnvironmentPolicyError("GitHub environment name must be non-empty")
    base = "https://api.github.com"
    return (
        f"{base}/repos/{quote(_repository_slug(repository), safe='/')}"
        f"/environments/{quote(environment, safe='')}"
    )


def _origin(url: str) -> tuple[str, str, int | None]:
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as error:
        raise EnvironmentPolicyError("GitHub API redirect URL is malformed") from error
    hostname = parsed.hostname
    if hostname is None:
        return ("", "", None)
    return (parsed.scheme.casefold(), hostname.casefold(), port)


class _SameOriginRedirectHandler(HTTPRedirectHandler):
    def redirect_request(  # type: ignore[no-untyped-def]
        self,
        req,
        fp,
        code,
        msg,
        headers,
        newurl,
    ):
        target = urljoin(req.full_url, newurl)
        if _origin(req.full_url) != _origin(target):
            raise EnvironmentPolicyError(
                "GitHub API redirected to a different origin"
            )
        return super().redirect_request(req, fp, code, msg, headers, target)


def _fetch_environment(
    repository: str,
    environment: str,
    token: str,
    *,
    api_url: str = GITHUB_API_URL,
) -> dict[str, Any]:
    if not token:
        raise EnvironmentPolicyError("GitHub API token is missing")
    request = Request(
        _environment_url(api_url, repository, environment),
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": USER_AGENT,
            "X-GitHub-Api-Version": GITHUB_API_VERSION,
        },
    )
    try:
        with build_opener(_SameOriginRedirectHandler()).open(
            request,
            timeout=20,
        ) as response:
            payload = response.read()
    except HTTPError as error:
        raise EnvironmentPolicyError(
            f"GitHub environment lookup failed with HTTP {error.code}"
        ) from error
    except (URLError, OSError, http.client.HTTPException) as error:
        raise EnvironmentPolicyError("GitHub environment lookup failed") from error
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EnvironmentPolicyError(
            "GitHub environment lookup returned invalid JSON"
        ) from error
    if not isinstance(value, dict):
        raise EnvironmentPolicyError("GitHub environment response is malformed")
    return value


def _reviewer_is_separate(
    reviewer: Mapping[str, Any],
    dispatcher: str,
) -> bool:
    reviewer_type = reviewer.get("type")
    subject = reviewer.get("reviewer")
    if not isinstance(subject, dict):
        raise EnvironmentPolicyError("GitHub reviewer identity is malformed")
    if reviewer_type == "User":
        login = subject.get("login")
        if not isinstance(login, str) or not login:
            raise EnvironmentPolicyError("GitHub user reviewer identity is malformed")
        return login.casefold() != dispatcher.casefold()
    if reviewer_type == "Team":
        slug = subject.get("slug")
        if not isinstance(slug, str) or not slug:
            raise EnvironmentPolicyError("GitHub team reviewer identity is malformed")
        # A team is a separate approval principal. GitHub's prevent_self_review
        # rule prevents the dispatcher from approving their own deployment even
        # when they belong to that team.
        return True
    raise EnvironmentPolicyError("GitHub reviewer type is unsupported")


def validate_environment_policy(
    payload: Mapping[str, Any],
    expected_environment: str,
    dispatcher: str,
) -> None:
    """Require the protected, independently reviewed credential environment."""

    if not isinstance(payload, Mapping):
        raise EnvironmentPolicyError("GitHub environment response is malformed")
    if not expected_environment or payload.get("name") != expected_environment:
        raise EnvironmentPolicyError("GitHub environment name does not match")
    if payload.get("can_admins_bypass") is not False:
        raise EnvironmentPolicyError(
            "GitHub environment administrator bypass must be disabled"
        )

    branch_policy = payload.get("deployment_branch_policy")
    if not isinstance(branch_policy, Mapping) or (
        branch_policy.get("protected_branches") is not True
        or branch_policy.get("custom_branch_policies") is not False
    ):
        raise EnvironmentPolicyError(
            "GitHub environment must allow protected branches only"
        )

    if not isinstance(dispatcher, str) or not dispatcher.strip():
        raise EnvironmentPolicyError("GitHub dispatch actor is missing")
    protection_rules = payload.get("protection_rules")
    if not isinstance(protection_rules, list):
        raise EnvironmentPolicyError(
            "GitHub environment protection rules are malformed"
        )
    reviewer_rules = [
        rule
        for rule in protection_rules
        if isinstance(rule, Mapping) and rule.get("type") == "required_reviewers"
    ]
    if not reviewer_rules:
        raise EnvironmentPolicyError(
            "GitHub environment must require an independent reviewer"
        )
    for rule in reviewer_rules:
        if rule.get("prevent_self_review") is not True:
            raise EnvironmentPolicyError(
                "GitHub environment must prevent self-review"
            )
        reviewers = rule.get("reviewers")
        if not isinstance(reviewers, list) or not reviewers:
            raise EnvironmentPolicyError(
                "GitHub environment required-reviewer list is empty"
            )
        if not any(
            _reviewer_is_separate(reviewer, dispatcher)
            for reviewer in reviewers
            if isinstance(reviewer, Mapping)
        ):
            raise EnvironmentPolicyError(
                "GitHub environment has no reviewer other than the dispatcher"
            )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", ""),
    )
    parser.add_argument("--environment", required=True)
    parser.add_argument(
        "--dispatcher",
        default=os.environ.get("GITHUB_ACTOR", ""),
    )
    parser.add_argument(
        "--api-url",
        default=os.environ.get("GITHUB_API_URL", GITHUB_API_URL),
    )
    parser.add_argument(
        "--token-env",
        default="GITHUB_TOKEN",
        help="environment variable containing the GitHub API token",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        payload = _fetch_environment(
            args.repository,
            args.environment,
            os.environ.get(args.token_env, ""),
            api_url=args.api_url,
        )
        validate_environment_policy(payload, args.environment, args.dispatcher)
    except EnvironmentPolicyError as error:
        print(f"GitHub environment policy verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"verified GitHub environment policy for {args.repository}/"
        f"{args.environment}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
