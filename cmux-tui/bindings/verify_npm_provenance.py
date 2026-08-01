#!/usr/bin/env python3
"""Verify npm ownership and bootstrap provenance with npm audit signatures."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


REGISTRY = "https://registry.npmjs.org"
PREDICATE_TYPE = "https://slsa.dev/provenance/v1"
USER_AGENT = "cmux-sdk-npm-provenance/1 (https://github.com/manaflow-ai/cmux)"


class ProvenanceError(RuntimeError):
    """Raised when npm cannot prove the expected package ownership."""


def _integrity(artifact: Path) -> str:
    digest = hashlib.sha512()
    with artifact.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha512-" + base64.b64encode(digest.digest()).decode("ascii")


def _metadata(package: str) -> dict[str, Any]:
    request = Request(
        f"{REGISTRY}/{quote(package, safe='')}",
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=20) as response:
            payload = response.read()
    except HTTPError as error:
        if error.code == 404:
            raise ProvenanceError("the required npm project does not exist") from error
        raise ProvenanceError("npm metadata lookup failed") from error
    except (URLError, OSError) as error:
        raise ProvenanceError("npm metadata lookup failed") from error
    try:
        metadata = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProvenanceError("npm returned invalid project metadata") from error
    if not isinstance(metadata, dict):
        raise ProvenanceError("npm returned invalid project metadata")
    return metadata


def _validate_metadata(
    metadata: dict[str, Any],
    package: str,
    version: str,
    repository_url: str,
    repository_directory: str,
    artifact: Optional[Path],
) -> None:
    if metadata.get("name") != package:
        raise ProvenanceError("npm metadata names a different project")
    versions = metadata.get("versions")
    release = versions.get(version) if isinstance(versions, dict) else None
    if not isinstance(release, dict):
        raise ProvenanceError("the required npm bootstrap release does not exist")
    if release.get("name") != package or release.get("version") != version:
        raise ProvenanceError("npm bootstrap release identity is malformed")

    tags = metadata.get("dist-tags")
    if not isinstance(tags, dict) or tags.get("bootstrap") != version:
        raise ProvenanceError("npm bootstrap tag does not name the ownership release")

    repository = release.get("repository")
    if not isinstance(repository, dict) or repository != {
        "type": "git",
        "url": repository_url,
        "directory": repository_directory,
    }:
        raise ProvenanceError("npm bootstrap repository identity does not match")

    publisher = release.get("_npmUser")
    publisher_name = publisher.get("name") if isinstance(publisher, dict) else None
    if not isinstance(publisher_name, str) or not publisher_name:
        raise ProvenanceError("npm bootstrap publisher identity is missing")
    maintainers = metadata.get("maintainers")
    if not isinstance(maintainers, list):
        raise ProvenanceError("npm project maintainer state is malformed")
    maintainer_names = [
        item.get("name") if isinstance(item, dict) else None
        for item in maintainers
    ]
    if maintainer_names != [publisher_name]:
        raise ProvenanceError(
            "npm bootstrap publisher is not the sole current project maintainer"
        )

    dist = release.get("dist")
    integrity = dist.get("integrity") if isinstance(dist, dict) else None
    attestations = dist.get("attestations") if isinstance(dist, dict) else None
    if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
        raise ProvenanceError("npm bootstrap integrity metadata is malformed")
    if artifact is not None:
        if not artifact.is_file():
            raise ProvenanceError("the expected npm bootstrap artifact does not exist")
        if integrity != _integrity(artifact):
            raise ProvenanceError("npm bootstrap bytes do not match the tested artifact")
    expected_attestation_url = (
        f"{REGISTRY}/-/npm/v1/attestations/{package}@{version}"
    )
    if not isinstance(attestations, dict) or attestations.get("url") != (
        expected_attestation_url
    ):
        raise ProvenanceError("npm bootstrap provenance endpoint is missing")
    provenance = attestations.get("provenance")
    if not isinstance(provenance, dict) or provenance.get("predicateType") != (
        PREDICATE_TYPE
    ):
        raise ProvenanceError("npm bootstrap provenance predicate is missing")


def _public_npm_environment(cache: Path) -> dict[str, str]:
    environment = {
        name: value
        for name, value in os.environ.items()
        if "TOKEN" not in name.upper()
        and "AUTH" not in name.upper()
        and not name.upper().startswith("NPM_CONFIG_")
    }
    environment.update(
        {
            "NPM_CONFIG_CACHE": str(cache),
            "NPM_CONFIG_GLOBALCONFIG": str(cache.parent / "global.npmrc"),
            "NPM_CONFIG_IGNORE_SCRIPTS": "true",
            "NPM_CONFIG_REGISTRY": REGISTRY,
            "NPM_CONFIG_USERCONFIG": str(cache.parent / "user.npmrc"),
        }
    )
    return environment


def _run_npm(package: str, version: str, npm: str) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-npm-provenance-") as root:
        project = Path(root)
        (project / "package.json").write_text(
            json.dumps({"name": "cmux-provenance-check", "private": True}),
            encoding="utf-8",
        )
        environment = _public_npm_environment(project / "cache")
        common = {
            "cwd": project,
            "env": environment,
            "encoding": "utf-8",
            "errors": "replace",
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "timeout": 120,
        }
        try:
            install = subprocess.run(
                [
                    npm,
                    "install",
                    "--ignore-scripts",
                    "--no-audit",
                    "--no-fund",
                    "--save-exact",
                    f"{package}@{version}",
                ],
                check=False,
                **common,
            )
            if install.returncode != 0:
                raise ProvenanceError("could not install the npm bootstrap release")
            audit = subprocess.run(
                [npm, "audit", "signatures", "--json"],
                check=False,
                **common,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ProvenanceError("could not verify npm bootstrap provenance") from error
        if audit.returncode != 0:
            raise ProvenanceError("npm bootstrap signature audit failed")
        try:
            result = json.loads(audit.stdout)
        except (TypeError, json.JSONDecodeError) as error:
            raise ProvenanceError("npm signature audit returned invalid output") from error
        if not isinstance(result, dict) or result.get("invalid") != [] or (
            result.get("missing") != []
        ):
            raise ProvenanceError("npm bootstrap signature audit was inconclusive")


def verify(
    package: str,
    version: str,
    repository_url: str,
    repository_directory: str,
    artifact: Optional[Path] = None,
    *,
    npm: str = "npm",
) -> None:
    if not all((package, version, repository_url, repository_directory, npm)):
        raise ProvenanceError("npm provenance inputs must be non-empty")
    _validate_metadata(
        _metadata(package),
        package,
        version,
        repository_url,
        repository_directory,
        artifact,
    )
    _run_npm(package, version, npm)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository-url", required=True)
    parser.add_argument("--repository-directory", required=True)
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--npm", default="npm")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        verify(
            args.package,
            args.version,
            args.repository_url,
            args.repository_directory,
            args.artifact,
            npm=args.npm,
        )
    except ProvenanceError as error:
        print(f"npm provenance verification failed: {error}", file=sys.stderr)
        return 1
    print(f"verified npm ownership provenance for {args.package}@{args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
