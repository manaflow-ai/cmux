#!/usr/bin/env python3
"""Verify exact crates.io repository and owner state before release tags."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Optional, Sequence
from urllib.parse import quote
from urllib.request import urlopen

from crates_io_client import API_INTERVAL_SECONDS, CratesIoClient, CratesIoRequestError

BOOTSTRAP_PACKAGES = frozenset(("cmux-sdk", "cmux-sidebar"))
BOOTSTRAP_REPOSITORY = "https://github.com/manaflow-ai/cmux"
BOOTSTRAP_OWNER_ID = 431397
BOOTSTRAP_OWNER_LOGIN = "lawrencecchen"
CRATES_IO_API_INTERVAL_SECONDS = API_INTERVAL_SECONDS


class OwnershipError(RuntimeError):
    """Raised when crates.io does not prove the expected current ownership."""


def _json(client: CratesIoClient, path: str) -> dict[str, Any]:
    try:
        payload = client.request_api(path)
        if payload is None:
            raise OwnershipError("a required crates.io project does not exist")
    except CratesIoRequestError as error:
        raise OwnershipError("crates.io ownership lookup failed") from error
    try:
        result = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OwnershipError("crates.io returned invalid ownership metadata") from error
    if not isinstance(result, dict):
        raise OwnershipError("crates.io returned invalid ownership metadata")
    return result


def _verify_package(
    client: CratesIoClient,
    package: str,
    repository: str,
    owner_id: int,
    owner_login: str,
    require_trusted_publishing: bool,
) -> None:
    base = f"/{quote(package, safe='')}"
    metadata = _json(client, base)
    crate = metadata.get("crate")
    if not isinstance(crate, dict) or crate.get("id") != package or (
        crate.get("name") != package
    ):
        raise OwnershipError(f"crates.io project identity is malformed for {package}")
    if crate.get("repository") != repository:
        raise OwnershipError(f"crates.io repository does not match for {package}")
    if require_trusted_publishing and crate.get("trustpub_only") is not True:
        raise OwnershipError(
            f"crates.io trusted publishing is not required for {package}"
        )

    ownership = _json(client, f"{base}/owners")
    users = ownership.get("users")
    teams = ownership.get("teams", [])
    expected = {
        "id": owner_id,
        "login": owner_login,
        "kind": "user",
        "url": f"https://github.com/{owner_login}",
    }
    if not isinstance(users, list) or not isinstance(teams, list):
        raise OwnershipError(f"crates.io owner state is malformed for {package}")
    if teams or len(users) != 1 or not isinstance(users[0], dict):
        raise OwnershipError(f"crates.io owner set does not match for {package}")
    actual = {key: users[0].get(key) for key in expected}
    if actual != expected:
        raise OwnershipError(f"crates.io owner does not match for {package}")


def verify(
    packages: Sequence[str],
    repository: str,
    owner_id: int,
    owner_login: str,
    *,
    require_trusted_publishing: bool = True,
) -> None:
    if not packages or not repository or owner_id <= 0 or not owner_login:
        raise OwnershipError("crates.io ownership inputs are invalid")
    if len(set(packages)) != len(packages) or any(not package for package in packages):
        raise OwnershipError("crates.io package names must be unique and non-empty")
    client = CratesIoClient(
        opener=urlopen,
        api_interval=CRATES_IO_API_INTERVAL_SECONDS,
    )
    for package in packages:
        _verify_package(
            client,
            package,
            repository,
            owner_id,
            owner_login,
            require_trusted_publishing,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", action="append", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--owner-id", required=True, type=int)
    parser.add_argument("--owner-login", required=True)
    parser.add_argument(
        "--bootstrap-ownership-only",
        action="store_true",
        help=(
            "verify one allowlisted cmux SDK reservation before trusted "
            "publishing is enabled"
        ),
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.bootstrap_ownership_only and (
            len(args.package) != 1
            or args.package[0] not in BOOTSTRAP_PACKAGES
            or args.repository != BOOTSTRAP_REPOSITORY
            or args.owner_id != BOOTSTRAP_OWNER_ID
            or args.owner_login != BOOTSTRAP_OWNER_LOGIN
        ):
            raise OwnershipError(
                "bootstrap ownership-only mode is restricted to one cmux-sdk "
                "or cmux-sidebar reservation"
            )
        verify(
            args.package,
            args.repository,
            args.owner_id,
            args.owner_login,
            require_trusted_publishing=not args.bootstrap_ownership_only,
        )
    except OwnershipError as error:
        print(f"crates.io ownership verification failed: {error}", file=sys.stderr)
        return 1
    print(f"verified crates.io ownership for {', '.join(args.package)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
