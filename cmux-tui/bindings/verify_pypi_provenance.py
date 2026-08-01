#!/usr/bin/env python3
"""Verify exact PyPI files were attested by a trusted publisher in one repo."""

from __future__ import annotations

import argparse
import json
from pathlib import PurePath
import subprocess
import sys
from typing import Any, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


USER_AGENT = "cmux-sdk-pypi-provenance/1"


class ProvenanceError(RuntimeError):
    """Raised when PyPI cannot prove the expected trusted-publisher identity."""


def _json(url: str, missing: str) -> dict[str, Any]:
    request = Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=20) as response:
            payload = response.read()
    except HTTPError as error:
        if error.code == 404:
            raise ProvenanceError(missing) from error
        raise ProvenanceError("PyPI provenance lookup failed") from error
    except (URLError, OSError) as error:
        raise ProvenanceError("PyPI provenance lookup failed") from error
    try:
        metadata = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProvenanceError("PyPI returned invalid provenance metadata") from error
    if not isinstance(metadata, dict):
        raise ProvenanceError("PyPI returned invalid provenance metadata")
    return metadata


def _metadata(package: str, version: str) -> dict[str, Any]:
    url = (
        "https://pypi.org/pypi/"
        f"{quote(package, safe='')}/{quote(version, safe='')}/json"
    )
    return _json(url, "the required PyPI release does not exist")


def _provenance(package: str, version: str, filename: str) -> dict[str, Any]:
    url = (
        "https://pypi.org/integrity/"
        f"{quote(package, safe='')}/{quote(version, safe='')}/"
        f"{quote(filename, safe='')}/provenance"
    )
    return _json(url, "the required PyPI provenance does not exist")


def _release_urls(metadata: dict[str, Any]) -> dict[str, str]:
    files = metadata.get("urls")
    if not isinstance(files, list):
        raise ProvenanceError("PyPI release metadata has no file list")
    urls: dict[str, str] = {}
    for item in files:
        if not isinstance(item, dict):
            raise ProvenanceError("PyPI release metadata contains an invalid file")
        filename = item.get("filename")
        url = item.get("url")
        if not isinstance(filename, str) or not isinstance(url, str):
            raise ProvenanceError("PyPI release metadata contains an invalid file")
        if filename in urls:
            raise ProvenanceError("PyPI release metadata contains a duplicate file")
        parsed = urlsplit(url)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "files.pythonhosted.org"
            or PurePath(parsed.path).name != filename
        ):
            raise ProvenanceError("PyPI release metadata contains an unsafe file URL")
        urls[filename] = url
    return urls


def _verify_ownership(
    metadata: dict[str, Any], expected_owners: Sequence[str]
) -> None:
    expected = set(expected_owners)
    if not expected or len(expected) != len(expected_owners):
        raise ProvenanceError("expected PyPI owners must be unique and non-empty")
    ownership = metadata.get("ownership")
    if not isinstance(ownership, dict) or ownership.get("organization") is not None:
        raise ProvenanceError("PyPI project ownership is missing or unexpected")
    roles = ownership.get("roles")
    if not isinstance(roles, list):
        raise ProvenanceError("PyPI project owner roles are malformed")
    actual: set[tuple[str, str]] = set()
    for item in roles:
        if not isinstance(item, dict):
            raise ProvenanceError("PyPI project owner roles are malformed")
        role = item.get("role")
        user = item.get("user")
        if not isinstance(role, str) or not isinstance(user, str):
            raise ProvenanceError("PyPI project owner roles are malformed")
        actual.add((role, user))
    expected_roles = {("Owner", owner) for owner in expected}
    if len(actual) != len(roles) or actual != expected_roles:
        raise ProvenanceError("PyPI project owner set does not match")


def _repository_slug(repository: str) -> str:
    parsed = urlsplit(repository)
    slug = parsed.path.strip("/")
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or len(slug.split("/")) != 2
    ):
        raise ProvenanceError("expected PyPI repository URL is invalid")
    return slug


def _verify_publisher(
    metadata: dict[str, Any],
    repository: str,
    workflow: str,
    environment: str,
) -> None:
    bundles = metadata.get("attestation_bundles")
    if metadata.get("version") != 1 or not isinstance(bundles, list) or (
        len(bundles) != 1
    ):
        raise ProvenanceError("PyPI provenance bundle set is malformed")
    bundle = bundles[0]
    publisher = bundle.get("publisher") if isinstance(bundle, dict) else None
    expected_publisher = {
        "environment": environment,
        "kind": "GitHub",
        "repository": _repository_slug(repository),
        "workflow": workflow,
    }
    if publisher != expected_publisher:
        raise ProvenanceError("PyPI trusted publisher identity does not match")
    attestations = bundle.get("attestations")
    if not isinstance(attestations, list) or not attestations:
        raise ProvenanceError("PyPI provenance attestation set is malformed")


def verify(
    package: str,
    version: str,
    filenames: Sequence[str],
    repository: str,
    owners: Sequence[str],
    workflow: str,
    environment: str,
) -> None:
    expected = set(filenames)
    if not all((package, version, repository, workflow, environment)) or not expected:
        raise ProvenanceError(
            "package, version, repository, and filenames must be non-empty"
        )
    if len(expected) != len(filenames):
        raise ProvenanceError("expected PyPI filenames must be unique")
    metadata = _metadata(package, version)
    _verify_ownership(metadata, owners)
    urls = _release_urls(metadata)
    if set(urls) != expected:
        raise ProvenanceError("PyPI release files differ from the expected bootstrap set")
    for filename in sorted(expected):
        _verify_publisher(
            _provenance(package, version, filename),
            repository,
            workflow,
            environment,
        )
        try:
            result = subprocess.run(
                [
                    "pypi-attestations",
                    "verify",
                    "pypi",
                    "--repository",
                    repository,
                    urls[filename],
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ProvenanceError(
                f"could not verify trusted-publisher provenance for {filename}"
            ) from error
        if result.returncode != 0:
            raise ProvenanceError(
                f"trusted-publisher provenance does not match for {filename}"
            )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--filename", action="append", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--owner", action="append", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--environment", required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        verify(
            args.package,
            args.version,
            args.filename,
            args.repository,
            args.owner,
            args.workflow,
            args.environment,
        )
    except ProvenanceError as error:
        print(f"PyPI provenance verification failed: {error}", file=sys.stderr)
        return 1
    print(
        f"verified PyPI provenance for {args.package}=={args.version} "
        f"({len(args.filename)} files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
