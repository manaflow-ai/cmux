#!/usr/bin/env python3
"""Verify exact PyPI files were attested by a trusted publisher in one repo."""

from __future__ import annotations

import argparse
import json
from pathlib import PurePosixPath
import re
import subprocess
import sys
import tempfile
from typing import Any, Mapping, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


USER_AGENT = "cmux-sdk-pypi-provenance/1"
SOURCE_REPOSITORY_DIGEST_OID = "1.3.6.1.4.1.57264.1.13"
SOURCE_REPOSITORY_REF_OID = "1.3.6.1.4.1.57264.1.14"
BUILD_CONFIG_URI_OID = "1.3.6.1.4.1.57264.1.18"
BUILD_CONFIG_DIGEST_OID = "1.3.6.1.4.1.57264.1.19"


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
            or PurePosixPath(parsed.path).name != filename
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
    if not isinstance(publisher, dict):
        raise ProvenanceError("PyPI trusted publisher identity is malformed")
    expected_identity = {
        "environment": environment,
        "kind": "GitHub",
        "repository": _repository_slug(repository),
        "workflow": workflow,
    }
    if any(
        publisher.get(key) != value
        for key, value in expected_identity.items()
    ):
        raise ProvenanceError("PyPI trusted publisher identity does not match")
    claims = publisher.get("claims")
    if claims is not None and not isinstance(claims, dict):
        raise ProvenanceError("PyPI trusted publisher claims are malformed")
    attestations = bundle.get("attestations")
    if not isinstance(attestations, list) or not attestations:
        raise ProvenanceError("PyPI provenance attestation set is malformed")


def _certificate_claim_sets(metadata: dict[str, Any]) -> list[Mapping[str, str]]:
    try:
        from pypi_attestations import Provenance
    except ImportError as error:
        raise ProvenanceError("the pinned PyPI provenance verifier is unavailable") from error
    try:
        provenance = Provenance.model_validate(metadata)
        claim_sets = [
            attestation.certificate_claims
            for bundle in provenance.attestation_bundles
            for attestation in bundle.attestations
        ]
    except (AttributeError, TypeError, ValueError) as error:
        raise ProvenanceError("PyPI certificate claims are malformed") from error
    if not claim_sets or any(not isinstance(claims, dict) for claims in claim_sets):
        raise ProvenanceError("PyPI certificate claims are malformed")
    return claim_sets


def _verify_stable_certificate_claims(
    metadata: dict[str, Any],
    repository: str,
    workflow: str,
    expected_commit: Optional[str],
    expected_ref: Optional[str],
) -> None:
    if expected_commit is None and expected_ref is None:
        return
    if expected_commit is None or expected_ref is None:
        raise ProvenanceError("expected PyPI commit and ref must be supplied together")
    if re.fullmatch(r"[0-9a-f]{40}", expected_commit) is None:
        raise ProvenanceError("expected PyPI commit must be a full lowercase Git SHA")
    if not expected_ref.startswith("refs/") or any(
        character.isspace() for character in expected_ref
    ):
        raise ProvenanceError("expected PyPI ref is invalid")

    repository_url = f"https://github.com/{_repository_slug(repository)}"
    expected = {
        SOURCE_REPOSITORY_DIGEST_OID: expected_commit,
        SOURCE_REPOSITORY_REF_OID: expected_ref,
        BUILD_CONFIG_URI_OID: (
            f"{repository_url}/.github/workflows/{workflow}@{expected_ref}"
        ),
        BUILD_CONFIG_DIGEST_OID: expected_commit,
    }
    for claims in _certificate_claim_sets(metadata):
        if any(claims.get(oid) != value for oid, value in expected.items()):
            raise ProvenanceError(
                "PyPI certificate claims do not match the expected release commit and ref"
            )


def verify(
    package: str,
    version: str,
    filenames: Sequence[str],
    repository: str,
    owners: Sequence[str],
    workflow: str,
    environment: str,
    expected_commit: Optional[str] = None,
    expected_ref: Optional[str] = None,
    *,
    authority_only: bool = False,
) -> None:
    expected = set(filenames)
    if not all((package, version, repository, workflow, environment)) or not expected:
        raise ProvenanceError(
            "package, version, repository, and filenames must be non-empty"
        )
    if len(expected) != len(filenames):
        raise ProvenanceError("expected PyPI filenames must be unique")
    if (expected_commit is None) != (expected_ref is None):
        raise ProvenanceError("expected PyPI commit and ref must be supplied together")
    if authority_only and expected_commit is not None:
        raise ProvenanceError(
            "authority-only PyPI verification cannot validate cryptographic claims"
        )
    metadata = _metadata(package, version)
    _verify_ownership(metadata, owners)
    urls = _release_urls(metadata)
    if set(urls) != expected:
        raise ProvenanceError("PyPI release files differ from the expected bootstrap set")
    for filename in sorted(expected):
        provenance_metadata = _provenance(package, version, filename)
        _verify_publisher(
            provenance_metadata,
            repository,
            workflow,
            environment,
        )
        if authority_only:
            continue
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                suffix=".json",
            ) as provenance_file:
                json.dump(provenance_metadata, provenance_file)
                provenance_file.flush()
                result = subprocess.run(
                    [
                        "pypi-attestations",
                        "verify",
                        "pypi",
                        "--repository",
                        repository,
                        "--provenance-file",
                        provenance_file.name,
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
        _verify_stable_certificate_claims(
            provenance_metadata,
            repository,
            workflow,
            expected_commit,
            expected_ref,
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
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-ref")
    parser.add_argument(
        "--authority-only",
        action="store_true",
        help="verify current PyPI registry authority without third-party verifier code",
    )
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
            args.expected_commit,
            args.expected_ref,
            authority_only=args.authority_only,
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
