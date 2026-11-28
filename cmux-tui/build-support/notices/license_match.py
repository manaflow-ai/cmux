#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Do a crate's shipped license texts satisfy its concluded SPDX expression?

The rule (shared with cmux-browser G2): at least one OR branch of the
expression must have a matching shipped text for EVERY license in that
branch. A text matches a license by its signature (phrases of the license
text, compared lower-case with whitespace collapsed). An id with no signature
here fails: add one after a review. `LicenseRef-*` is satisfied by any
shipped file (the file is the license). `<id> WITH <exception>` needs the
text of <id> and, where a signature exists, of the exception.

iroh 1.0.3 declares MIT OR Apache-2.0 and shipped only LICENSE-BSD3 (the
Tailscale notice): any license file used to pass, so no MIT or Apache text
shipped. That is what this module stops.
"""

from __future__ import annotations

import re

_P = "permission is hereby granted, free of charge, to any person obtaining a copy"
SIGNATURES: dict[str, list[list[str]]] = {
    # Each id: a list of alternatives; an alternative matches when every
    # phrase is in the text and no phrase prefixed with "!" is.
    "MIT": [[_P, "the above copyright notice and this permission notice shall be included"]],
    "MIT-0": [[_P, "!the above copyright notice and this permission notice shall be included"]],
    "Apache-2.0": [["apache license", "version 2.0", "terms and conditions for use, reproduction, and distribution", "grant of copyright license"]],
    "BSD-2-Clause": [["redistribution and use in source and binary forms", "redistributions of source code must retain the above copyright notice", "!neither the name"]],
    "BSD-3-Clause": [["redistribution and use in source and binary forms", "redistributions of source code must retain the above copyright notice", "neither the name"]],
    "ISC": [["permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted", "provided that the above copyright notice and this permission notice appear in all copies"],
            ["permission to use, copy, modify, and distribute this software for any purpose with or without fee is hereby granted", "provided that the above copyright notice and this permission notice appear in all copies"]],
    "0BSD": [["permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted", "!provided that the above copyright notice"]],
    "Zlib": [["this software is provided 'as-is', without any express or implied warranty", "altered source versions must be plainly marked as such"]],
    "Unlicense": [["this is free and unencumbered software released into the public domain"]],
    "CC0-1.0": [["cc0 1.0 universal"], ["creative commons legal code", "cc0"]],
    "MPL-2.0": [["mozilla public license version 2.0"], ["mozilla public license, version 2.0"]],
    "BSL-1.0": [["boost software license - version 1.0"]],
    "Unicode-3.0": [["unicode license v3"], ["unicode, inc. license agreement - data files and software", "permission is hereby granted"]],
    # The Unicode data license: the 2016 agreement and its successor (v3)
    # share the permission grant for "Data Files" and "Software".
    "Unicode-DFS-2016": [["unicode, inc. license agreement - data files and software", "permission is hereby granted"],
                         ["unicode", "permission is hereby granted, free of charge, to any person obtaining a copy of", "data files"]],
    "CDLA-Permissive-2.0": [["community data license agreement - permissive - version 2.0"], ["cdla-permissive-2.0"]],
    "OpenSSL": [["openssl license", "redistribution and use in source and binary forms"]],
    "WTFPL": [["do what the fuck you want to public license"]],
    "GPL-3.0-only": [["gnu general public license", "version 3"]],
    "GPL-3.0-or-later": [["gnu general public license", "version 3"]],
    "LLVM-exception": [["llvm exceptions to the apache 2.0 license"]],
    "bzip2-1.0.6": [["bzip2", "redistribution and use in source and binary forms"]],
}
TOKEN = re.compile(r"\(|\)|[A-Za-z0-9.+:-]+")


def normalize(text: str) -> str:
    text = text.lower().replace("’", "'").replace("‘", "'")
    # Comment and markdown markers at the start of a line (`//`, `#`, `*`, `>`).
    text = re.sub(r"(?m)^[ \t]*(?://+|#+|\*+|>+)", " ", text)
    return re.sub(r"\s+", " ", text)


def matches(license_id: str, text: str) -> bool:
    body = normalize(text)
    for alternative in SIGNATURES.get(license_id, []):
        if all((phrase[1:] not in body) if phrase.startswith("!") else (phrase in body) for phrase in alternative):
            return True
    return False


class ExpressionError(ValueError):
    pass


def branches(expression: str) -> list[list[str]]:
    """Disjunctive normal form: each branch is the list of ids that must all hold.
    `A WITH B` stays one term "A WITH B"."""
    tokens = TOKEN.findall(expression)
    position = 0

    def peek() -> str | None:
        return tokens[position] if position < len(tokens) else None

    def take() -> str:
        nonlocal position
        if position >= len(tokens):
            raise ExpressionError(f"unexpected end of {expression!r}")
        position += 1
        return tokens[position - 1]

    def primary() -> list[list[str]]:
        token = take()
        if token == "(":
            result = disjunction()
            if take() != ")":
                raise ExpressionError(f"unbalanced parentheses in {expression!r}")
            return result
        if token in (")", "AND", "OR", "WITH"):
            raise ExpressionError(f"unexpected {token!r} in {expression!r}")
        if peek() == "WITH":
            take()
            token = f"{token} WITH {take()}"
        return [[token]]

    def conjunction() -> list[list[str]]:
        result = primary()
        while peek() == "AND":
            take()
            right = primary()
            result = [a + b for a in result for b in right]
        return result

    def disjunction() -> list[list[str]]:
        result = conjunction()
        while peek() == "OR":
            take()
            result = result + conjunction()
        return result

    result = disjunction()
    if position != len(tokens):
        raise ExpressionError(f"trailing tokens in {expression!r}")
    return result


def term_problem(term: str, texts: list[str]) -> str | None:
    """None when the shipped texts satisfy one term."""
    if term.startswith("LicenseRef-"):
        return None if texts else f"{term}: no shipped file"
    base, _, exception = term.partition(" WITH ")
    for license_id in filter(None, (base, exception)):
        if license_id not in SIGNATURES:
            return f"{license_id}: unknown license id (no text signature; review and add one)"
        if not any(matches(license_id, text) for text in texts):
            return f"{license_id}: no shipped text matches"
    return None


def expression_problem(expression: str, texts: list[str]) -> str | None:
    """None when at least one OR branch is fully covered by the texts."""
    try:
        options = branches(expression)
    except ExpressionError as error:
        return str(error)
    reasons = []
    for branch in options:
        problems = [p for p in (term_problem(term, texts) for term in branch) if p]
        if not problems:
            return None
        reasons.append(" AND ".join(branch) + " (" + "; ".join(problems) + ")")
    return "no branch of " + repr(expression) + " is covered: " + " | ".join(reasons)
