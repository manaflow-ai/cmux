#!/usr/bin/env python3
"""Verify npm ownership and bootstrap provenance with npm audit signatures."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Optional, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

from sri import SRIError, strongest_sri_entries


REGISTRY = "https://registry.npmjs.org"
PREDICATE_TYPE = "https://slsa.dev/provenance/v1"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
GITHUB_REPOSITORY = "https://github.com/manaflow-ai/cmux"
GITHUB_REPOSITORY_ID = "1144115288"
GITHUB_REPOSITORY_OWNER_ID = "171392238"
GITHUB_RELEASE_EVENT = "repository_dispatch"
GITHUB_WORKFLOW_BUILD_TYPE = (
    "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
)
GITHUB_HOSTED_BUILDER = "https://github.com/actions/runner/github-hosted"
GITHUB_ACTIONS_PUBLISHER = "GitHub Actions"
GITHUB_ACTIONS_PUBLISHER_EMAIL = "npm-oidc-no-reply@github.com"
USER_AGENT = "cmux-sdk-npm-provenance/1 (https://github.com/manaflow-ai/cmux)"


class ProvenanceError(RuntimeError):
    """Raised when npm cannot prove the expected package ownership."""


def _integrity(artifact: Path) -> str:
    digest = hashlib.sha512()
    with artifact.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha512-" + base64.b64encode(digest.digest()).decode("ascii")


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
        raise ProvenanceError("npm provenance lookup failed") from error
    except (URLError, OSError, http.client.IncompleteRead) as error:
        raise ProvenanceError("npm provenance lookup failed") from error
    try:
        metadata = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProvenanceError("npm returned invalid provenance metadata") from error
    if not isinstance(metadata, dict):
        raise ProvenanceError("npm returned invalid provenance metadata")
    return metadata


def _metadata(package: str) -> dict[str, Any]:
    return _json(
        f"{REGISTRY}/{quote(package, safe='')}",
        "the required npm project does not exist",
    )


def _validate_metadata(
    metadata: dict[str, Any],
    package: str,
    version: str,
    repository_url: str,
    repository_directory: str,
    artifact: Optional[Path],
    owner: str,
    dist_tag: str,
    required_dist_tags: Sequence[str],
    publisher_type: str,
) -> tuple[str, str]:
    if metadata.get("name") != package:
        raise ProvenanceError("npm metadata names a different project")
    versions = metadata.get("versions")
    release = versions.get(version) if isinstance(versions, dict) else None
    if not isinstance(release, dict):
        raise ProvenanceError("the required npm bootstrap release does not exist")
    if release.get("name") != package or release.get("version") != version:
        raise ProvenanceError("npm bootstrap release identity is malformed")

    tags = metadata.get("dist-tags")
    if not isinstance(tags, dict) or tags.get(dist_tag) != version:
        raise ProvenanceError("npm dist-tag does not name the expected release")
    if any(
        not isinstance(tags.get(required_tag), str)
        or not tags[required_tag]
        for required_tag in required_dist_tags
    ):
        raise ProvenanceError("npm required dist-tag is missing")
    for required_tag in required_dist_tags:
        tagged_version = tags[required_tag]
        if not isinstance(versions.get(tagged_version), dict):
            raise ProvenanceError("npm required dist-tag names an unknown release")
        version_without_build = tagged_version.split("+", 1)[0]
        if required_tag == "latest" and "-" in version_without_build:
            # npm requires a latest tag even when the ownership bootstrap is
            # the project's sole release. A later release must replace it.
            if tagged_version != version or len(versions) != 1:
                raise ProvenanceError("npm latest dist-tag names a prerelease")

    repository = release.get("repository")
    if not isinstance(repository, dict) or repository != {
        "type": "git",
        "url": repository_url,
        "directory": repository_directory,
    }:
        raise ProvenanceError("npm bootstrap repository identity does not match")

    publisher = release.get("_npmUser")
    publisher_name = publisher.get("name") if isinstance(publisher, dict) else None
    if publisher_type == "owner":
        if publisher_name != owner:
            raise ProvenanceError("npm release publisher identity does not match")
    elif publisher_type == "github-actions":
        trusted = (
            publisher.get("trustedPublisher")
            if isinstance(publisher, dict)
            else None
        )
        oidc_config = trusted.get("oidcConfigId") if isinstance(trusted, dict) else None
        if (
            publisher_name != GITHUB_ACTIONS_PUBLISHER
            or publisher.get("email") != GITHUB_ACTIONS_PUBLISHER_EMAIL
            or not isinstance(trusted, dict)
            or trusted.get("id") != "github"
            or not isinstance(oidc_config, str)
            or not oidc_config.startswith("oidc:")
        ):
            raise ProvenanceError("npm release publisher identity does not match")
    else:
        raise ProvenanceError("npm publisher type is unsupported")
    maintainers = metadata.get("maintainers")
    if not isinstance(maintainers, list):
        raise ProvenanceError("npm project maintainer state is malformed")
    maintainer_names = [
        item.get("name") if isinstance(item, dict) else None
        for item in maintainers
    ]
    if maintainer_names != [owner]:
        raise ProvenanceError(
            "expected npm owner is not the sole current project maintainer"
        )

    dist = release.get("dist")
    integrity = dist.get("integrity") if isinstance(dist, dict) else None
    attestations = dist.get("attestations") if isinstance(dist, dict) else None
    if not isinstance(integrity, str):
        raise ProvenanceError("npm bootstrap integrity metadata is malformed")
    try:
        algorithm, sha512_entries = strongest_sri_entries(integrity)
    except SRIError as error:
        raise ProvenanceError(
            "npm bootstrap integrity metadata is malformed"
        ) from error
    if algorithm != "sha512":
        raise ProvenanceError("npm bootstrap integrity metadata is malformed")
    if artifact is not None:
        if not artifact.is_file():
            raise ProvenanceError("the expected npm bootstrap artifact does not exist")
        selected_integrity = _integrity(artifact)
        if selected_integrity not in sha512_entries:
            raise ProvenanceError("npm bootstrap bytes do not match the tested artifact")
    else:
        if len(sha512_entries) != 1:
            raise ProvenanceError("npm bootstrap integrity metadata is not unique")
        selected_integrity = next(iter(sha512_entries))
        _sha512_hex(selected_integrity)
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
    return selected_integrity, expected_attestation_url


def _sha512_hex(integrity: str) -> str:
    algorithm, separator, encoded = integrity.partition("-")
    if algorithm != "sha512" or separator != "-" or not encoded:
        raise ProvenanceError("npm bootstrap integrity metadata is malformed")
    try:
        digest = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ProvenanceError("npm bootstrap integrity metadata is malformed") from error
    if len(digest) != hashlib.sha512().digest_size:
        raise ProvenanceError("npm bootstrap integrity metadata is malformed")
    return digest.hex()


def _validate_attestation(
    metadata: dict[str, Any],
    package: str,
    version: str,
    integrity: str,
    workflow: str,
    workflow_ref: str,
    expected_commit: Optional[str],
) -> None:
    attestations = metadata.get("attestations")
    if not isinstance(attestations, list):
        raise ProvenanceError("npm bootstrap attestation list is malformed")
    matching = [
        item
        for item in attestations
        if isinstance(item, dict) and item.get("predicateType") == PREDICATE_TYPE
    ]
    if len(matching) != 1:
        raise ProvenanceError("npm bootstrap provenance attestation is not unique")
    bundle = matching[0].get("bundle")
    envelope = bundle.get("dsseEnvelope") if isinstance(bundle, dict) else None
    payload = envelope.get("payload") if isinstance(envelope, dict) else None
    if not isinstance(payload, str):
        raise ProvenanceError("npm bootstrap provenance envelope is malformed")
    try:
        statement = json.loads(base64.b64decode(payload, validate=True))
    except (
        ValueError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        binascii.Error,
    ) as error:
        raise ProvenanceError("npm bootstrap provenance payload is malformed") from error
    if not isinstance(statement, dict):
        raise ProvenanceError("npm bootstrap provenance payload is malformed")
    expected_subject = [{
        "name": f"pkg:npm/{package}@{version}",
        "digest": {"sha512": _sha512_hex(integrity)},
    }]
    if statement.get("_type") != STATEMENT_TYPE or (
        statement.get("predicateType") != PREDICATE_TYPE
    ) or statement.get("subject") != expected_subject:
        raise ProvenanceError("npm bootstrap provenance subject does not match")

    predicate = statement.get("predicate")
    definition = (
        predicate.get("buildDefinition") if isinstance(predicate, dict) else None
    )
    if not isinstance(definition, dict) or definition.get("buildType") != (
        GITHUB_WORKFLOW_BUILD_TYPE
    ):
        raise ProvenanceError("npm bootstrap provenance build type does not match")
    external = definition.get("externalParameters")
    workflow_identity = (
        external.get("workflow") if isinstance(external, dict) else None
    )
    if not isinstance(workflow_identity, dict) or (
        workflow_identity.get("repository") != GITHUB_REPOSITORY
        or workflow_identity.get("path") != workflow
        or workflow_identity.get("ref") != workflow_ref
    ):
        raise ProvenanceError("npm bootstrap provenance workflow does not match")
    if expected_commit is not None:
        expected_source = [{
            "uri": f"git+{GITHUB_REPOSITORY}@{workflow_ref}",
            "digest": {"gitCommit": expected_commit},
        }]
        if definition.get("resolvedDependencies") != expected_source:
            raise ProvenanceError("npm provenance source commit does not match")
    internal = definition.get("internalParameters")
    github = internal.get("github") if isinstance(internal, dict) else None
    if not isinstance(github, dict) or (
        github.get("event_name") != GITHUB_RELEASE_EVENT
        or github.get("repository_id") != GITHUB_REPOSITORY_ID
        or github.get("repository_owner_id") != GITHUB_REPOSITORY_OWNER_ID
    ):
        raise ProvenanceError("npm bootstrap provenance repository does not match")
    run_details = predicate.get("runDetails")
    builder = run_details.get("builder") if isinstance(run_details, dict) else None
    build_metadata = (
        run_details.get("metadata") if isinstance(run_details, dict) else None
    )
    invocation = (
        build_metadata.get("invocationId")
        if isinstance(build_metadata, dict)
        else None
    )
    invocation_pattern = re.escape(GITHUB_REPOSITORY) + (
        r"/actions/runs/[1-9][0-9]*/attempts/[1-9][0-9]*"
    )
    if not isinstance(builder, dict) or builder.get("id") != GITHUB_HOSTED_BUILDER:
        raise ProvenanceError("npm bootstrap provenance builder does not match")
    if not isinstance(invocation, str) or re.fullmatch(
        invocation_pattern, invocation
    ) is None:
        raise ProvenanceError("npm bootstrap provenance invocation does not match")


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
    owner: str,
    workflow: str,
    workflow_ref: str,
    dist_tag: str,
    publisher: str,
    required_dist_tags: Sequence[str] = (),
    expected_commit: Optional[str] = None,
    npm: str = "npm",
) -> None:
    if not all(
        (
            package,
            version,
            repository_url,
            repository_directory,
            owner,
            workflow,
            workflow_ref,
            dist_tag,
            *required_dist_tags,
            publisher,
            npm,
        )
    ):
        raise ProvenanceError("npm provenance inputs must be non-empty")
    if publisher == "github-actions" and expected_commit is None:
        raise ProvenanceError(
            "stable npm provenance requires an expected source commit"
        )
    if expected_commit is not None and re.fullmatch(
        r"[0-9a-f]{40}", expected_commit
    ) is None:
        raise ProvenanceError("expected npm provenance source commit is invalid")
    integrity, attestation_url = _validate_metadata(
        _metadata(package),
        package,
        version,
        repository_url,
        repository_directory,
        artifact,
        owner,
        dist_tag,
        required_dist_tags,
        publisher,
    )
    attestation = _json(
        attestation_url,
        "npm bootstrap provenance endpoint does not exist",
    )
    _validate_attestation(
        attestation,
        package,
        version,
        integrity,
        workflow,
        workflow_ref,
        expected_commit,
    )
    _run_npm(package, version, npm)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository-url", required=True)
    parser.add_argument("--repository-directory", required=True)
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--workflow-ref", required=True)
    parser.add_argument("--expected-commit")
    parser.add_argument("--dist-tag", required=True)
    parser.add_argument(
        "--require-dist-tag",
        action="append",
        default=[],
        dest="required_dist_tags",
    )
    parser.add_argument(
        "--publisher",
        choices=("owner", "github-actions"),
        required=True,
    )
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
            owner=args.owner,
            workflow=args.workflow,
            workflow_ref=args.workflow_ref,
            expected_commit=args.expected_commit,
            dist_tag=args.dist_tag,
            required_dist_tags=args.required_dist_tags,
            publisher=args.publisher,
            npm=args.npm,
        )
    except ProvenanceError as error:
        print(f"npm provenance verification failed: {error}", file=sys.stderr)
        return 1
    print(f"verified npm ownership provenance for {args.package}@{args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
