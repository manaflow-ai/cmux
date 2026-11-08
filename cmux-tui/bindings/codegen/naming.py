"""Language-neutral identifier naming helpers."""

from __future__ import annotations

import re
from collections.abc import Iterable

_WORD_BOUNDARY_1 = re.compile(r"([a-z0-9])([A-Z])")
_WORD_BOUNDARY_2 = re.compile(r"([A-Z]+)([A-Z][a-z])")
_NON_ALNUM = re.compile(r"[^A-Za-z0-9]+")
_MULTIPLE_UNDERSCORES = re.compile(r"_+")


def words(value: str) -> tuple[str, ...]:
    """Split a wire name or identifier into lowercase words."""

    separated = _WORD_BOUNDARY_2.sub(r"\1 \2", value)
    separated = _WORD_BOUNDARY_1.sub(r"\1 \2", separated)
    return tuple(part.lower() for part in _NON_ALNUM.split(separated) if part)


def snake_case(value: str) -> str:
    return "_".join(words(value))


def screaming_snake_case(value: str) -> str:
    return snake_case(value).upper()


def pascal_case(value: str) -> str:
    return "".join(part[:1].upper() + part[1:] for part in words(value))


def camel_case(value: str) -> str:
    parts = words(value)
    if not parts:
        return ""
    return parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])


def safe_identifier(
    value: str,
    *,
    style: str = "snake",
    reserved: Iterable[str] = (),
    reserved_suffix: str = "_",
) -> str:
    """Return a valid identifier in the requested style.

    Emitters supply their own reserved-word set because keywords differ by
    language. Empty names become ``_`` and leading digits are prefixed with an
    underscore.
    """

    converters = {
        "snake": snake_case,
        "screaming_snake": screaming_snake_case,
        "pascal": pascal_case,
        "camel": camel_case,
    }
    try:
        identifier = converters[style](value)
    except KeyError as error:
        raise ValueError(f"unknown identifier style: {style}") from error
    if not identifier:
        identifier = "_"
    if identifier[0].isdigit():
        identifier = f"_{identifier}"
    if identifier in frozenset(reserved):
        identifier = f"{identifier}{reserved_suffix}"
    return identifier


def normalized_identifier(value: str) -> str:
    """Normalize an already formatted identifier for collision checks."""

    normalized = _NON_ALNUM.sub("_", value)
    normalized = _MULTIPLE_UNDERSCORES.sub("_", normalized).strip("_")
    return normalized.casefold()


def find_collisions(values: Iterable[str], *, style: str) -> dict[str, tuple[str, ...]]:
    """Return deterministic collisions after applying a naming style."""

    groups: dict[str, list[str]] = {}
    for value in values:
        identifier = safe_identifier(value, style=style)
        groups.setdefault(identifier, []).append(value)
    return {
        identifier: tuple(sorted(originals))
        for identifier, originals in sorted(groups.items())
        if len(originals) > 1
    }
