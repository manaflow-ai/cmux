#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared data types of the notices tools (rust_notices.py)."""

from __future__ import annotations

import dataclasses
import hashlib
import re

CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
LICENSE_FILE = re.compile(
    r"^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)([-._].*)?$", re.I
)
TOOL = "rust_notices.py"
CRATE_DIR = re.compile(r"^[A-Za-z0-9_-]+-\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]*)?$")


class NoticeError(RuntimeError):
    pass


# Cargo.lock -----------------------------------------------------------------


@dataclasses.dataclass(frozen=True, order=True)
class Key:
    name: str
    version: str


@dataclasses.dataclass
class LockPackage:
    key: Key
    source: str | None
    checksum: str | None
    deps: list[Key]


# Model -------------------------------------------------------------------------


@dataclasses.dataclass
class LicenseFile:
    name: str  # path inside the crate directory (or reviewed:<name>)
    data: bytes

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()


def utf8(crate: "Crate", lf: LicenseFile) -> str:
    try:
        return lf.data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise NoticeError(f"{crate.key.name} {crate.key.version}: {lf.name} is not UTF-8 ({error}); the notices print texts verbatim, so convert nothing and review the file") from None


@dataclasses.dataclass
class Crate:
    key: Key
    first_party: bool
    declared: str
    concluded: str
    download: str
    checksum: str | None
    files: list[LicenseFile]
    closure: str  # "exact (cargo tree)" or "lock text"
    roots: list[str]


def spdx_expression(text: str | None) -> str | None:
    if not text:
        return None
    # Cargo's legacy "A/B" separator means A OR B.
    return " OR ".join(part.strip() for part in text.split("/")) if "/" in text else text.strip()


def or_alternatives(expression: str) -> list[str]:
    """Top-level OR terms of an SPDX expression; a term wrapped in one pair of
    parentheses is unwrapped ("(MIT OR Apache-2.0) AND X" stays one term)."""

    def split(text: str) -> list[str]:
        terms, depth, current = [], 0, []
        for token in re.split(r"(\(|\)|\s+OR\s+)", text):
            depth += token == "("
            depth -= token == ")"
            if depth == 0 and re.fullmatch(r"\s+OR\s+", token):
                terms.append("".join(current).strip())
                current = []
            else:
                current.append(token)
        terms.append("".join(current).strip())
        return terms

    def unwrap(term: str) -> str:
        if not (term.startswith("(") and term.endswith(")")):
            return term
        depth = 0
        for char in term[1:-1]:
            depth += char == "("
            depth -= char == ")"
            if depth < 0:  # "(A) AND (B)": the outer parentheses do not pair
                return term
        return term[1:-1].strip()

    return [unwrap(term) for term in split(expression)]


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]+", "-", text).strip("-")


