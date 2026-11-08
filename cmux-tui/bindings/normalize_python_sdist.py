#!/usr/bin/env python3
"""Rewrite a Python source distribution with deterministic archive metadata."""

from __future__ import annotations

import argparse
import copy
import gzip
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile
import tempfile
from typing import Optional, Sequence


class NormalizationError(RuntimeError):
    """Raised when an sdist cannot be normalized safely."""


def _safe_member(member: tarfile.TarInfo) -> None:
    path = PurePosixPath(member.name)
    if path.is_absolute() or not path.parts or any(
        part in ("", ".", "..") for part in path.parts
    ):
        raise NormalizationError(f"unsafe sdist member name: {member.name!r}")
    if not (member.isfile() or member.isdir()):
        raise NormalizationError(
            f"unsupported sdist member type for {member.name!r}"
        )


def _normalized_member(
    member: tarfile.TarInfo,
    epoch: int,
) -> tarfile.TarInfo:
    normalized = copy.copy(member)
    normalized.mtime = epoch
    normalized.uid = 0
    normalized.gid = 0
    normalized.uname = ""
    normalized.gname = ""
    normalized.pax_headers = {}
    if normalized.isdir():
        normalized.mode = 0o755
    else:
        normalized.mode = 0o755 if member.mode & 0o111 else 0o644
    return normalized


def normalize(archive: Path, epoch: int) -> None:
    if not archive.is_file():
        raise NormalizationError(f"source distribution does not exist: {archive}")
    if epoch < 0 or epoch > 0xFFFFFFFF:
        raise NormalizationError("source distribution epoch is outside gzip range")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{archive.name}.",
        suffix=".tmp",
        dir=archive.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with tarfile.open(archive, "r:gz") as source:
            members = source.getmembers()
            if not members:
                raise NormalizationError("source distribution is empty")
            names = [member.name for member in members]
            if len(names) != len(set(names)):
                raise NormalizationError("source distribution has duplicate members")
            for member in members:
                _safe_member(member)

            with temporary.open("wb") as output:
                with gzip.GzipFile(
                    filename="",
                    mode="wb",
                    fileobj=output,
                    compresslevel=9,
                    mtime=epoch,
                ) as compressed:
                    with tarfile.open(
                        fileobj=compressed,
                        mode="w",
                        format=tarfile.PAX_FORMAT,
                    ) as destination:
                        for member in sorted(members, key=lambda item: item.name):
                            contents = (
                                source.extractfile(member)
                                if member.isfile()
                                else None
                            )
                            try:
                                destination.addfile(
                                    _normalized_member(member, epoch),
                                    contents,
                                )
                            finally:
                                if contents is not None:
                                    contents.close()
        os.chmod(temporary, archive.stat().st_mode & 0o777)
        os.replace(temporary, archive)
    except (OSError, tarfile.TarError) as error:
        raise NormalizationError("could not normalize source distribution") from error
    finally:
        temporary.unlink(missing_ok=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--epoch", type=int, required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        normalize(args.archive, args.epoch)
    except NormalizationError as error:
        print(f"source distribution normalization failed: {error}", file=sys.stderr)
        return 1
    print(f"normalized Python source distribution: {args.archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
