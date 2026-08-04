#!/usr/bin/env python3
"""Validate a coordinated SDK version before release tags are created."""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable


SDK_TAG_PREFIX = "cmux-sdk-v"
SEMANTIC_VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
)


def parse_version(value: str) -> tuple[int, int, int]:
    match = SEMANTIC_VERSION.fullmatch(value)
    if match is None:
        raise ValueError("version must match stable X.Y.Z")
    return tuple(int(component) for component in match.groups())


def validate_release_version(
    candidate: str,
    existing_tags: Iterable[str] = (),
    *,
    require_newer: bool = False,
    require_latest: bool = False,
) -> tuple[int, int, int] | None:
    if require_newer and require_latest:
        raise ValueError("release validation modes are mutually exclusive")
    candidate_version = parse_version(candidate)
    if candidate_version[0] >= 2:
        raise ValueError(
            "major version must be 0 or 1 until the Go module path has a /vN suffix"
        )

    if not require_newer and not require_latest:
        return None

    existing_versions: list[tuple[int, int, int]] = []
    for tag in existing_tags:
        tag = tag.strip()
        if not tag.startswith(SDK_TAG_PREFIX):
            continue
        try:
            existing_versions.append(parse_version(tag.removeprefix(SDK_TAG_PREFIX)))
        except ValueError:
            continue

    latest = max(existing_versions, default=None)
    if latest is not None and candidate_version <= latest:
        latest_text = ".".join(str(component) for component in latest)
        if require_newer:
            raise ValueError(
                f"version {candidate} must be greater than latest SDK release {latest_text}"
            )
        if candidate_version < latest:
            raise ValueError(
                f"version {candidate} is older than latest SDK release {latest_text}"
            )
    return latest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--require-newer-than-tags",
        action="store_true",
        help="read existing tag names from stdin and require a strict increase",
    )
    modes.add_argument(
        "--require-latest-tag",
        action="store_true",
        help="read existing tag names from stdin and reject an older version",
    )
    arguments = parser.parse_args(argv)

    reads_tags = arguments.require_newer_than_tags or arguments.require_latest_tag
    tags = sys.stdin if reads_tags else ()
    try:
        latest = validate_release_version(
            arguments.version,
            tags,
            require_newer=arguments.require_newer_than_tags,
            require_latest=arguments.require_latest_tag,
        )
    except ValueError as error:
        print(f"SDK release version error: {error}", file=sys.stderr)
        return 1

    if reads_tags:
        latest_text = (
            "none"
            if latest is None
            else ".".join(str(component) for component in latest)
        )
        print(f"SDK release version ok: {arguments.version} (latest: {latest_text})")
    else:
        print(f"SDK release version ok: {arguments.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
