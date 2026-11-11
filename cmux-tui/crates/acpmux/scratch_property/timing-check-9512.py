#!/usr/bin/env python3
"""Find wall-clock ratio and percentile asserts in a cmux checkout's default Rust test run.

The class (docs/handbook/timing-on-a-busy-host.md, fix 7): a test in the default, non-ignored run
times work on the wall clock and asserts a ratio of two timings (`busy < idle * 4`, `busy / idle < 4`)
or an upper bound on a percentile (`p95 < bound`). CI runs cmux-tui's tests under cargo-nextest, one
process per test and every test binary at once, so the load beside the test sets the number: cmux#41346
went red on `busy < idle * 4` in acpmux's lib run, fixed in cmux#41391. Keep a deterministic ordering or
liveness check in the default run and move the ratio to an `#[ignore]`d test for its own run
(`--ignored --exact --test-threads=1`), or give it every test thread in nextest
(`threads-required = 'num-test-threads'` in cmux-tui/.config/nextest.toml).

Usage: python3 tools/rust-timing-ratio/check.py CMUX_CHECKOUT [PATH ...]
       python3 tools/rust-timing-ratio/check.py --self-test
PATH defaults to CMUX_CHECKOUT/cmux-tui/crates. Exit 1 when it finds one, 2 when the checkout or a
scan root is missing or holds no .rs file. tools/agent-guards/test_rust_timing_ratio.py runs its
fixtures in CI (Skills tests, "Validate agent guards"); no CI step scans a cmux checkout.

How it reads a test: a Rust tokenizer (comments, strings, raw strings, chars and lifetimes) and an
expression parser for the assert macros (assert!, debug_assert!, assert_eq!, assert_ne!, their
debug_ and prop_ forms): paths, calls, methods, fields, indexing, casts, unary and binary operators by
Rust precedence. It follows the test body's `let`, `for`, assignment and `push` statements, so a name
holds what it was built from: `t.elapsed()`, `Instant::now() - t`, `x.duration_since(t)`, a local fn
that reads the clock, a Vec of those, a percentile of them (`percentile(&v, 0.95)`, `stats.p99`,
`let p99 = sorted[..]`). It flags a comparison when
  - one side is a ratio of two timings (`busy / idle`) and the other anything, or both sides are
    timings and one is scaled by a constant (`busy < idle * MAX_RATIO`, `4 * idle > busy`);
  - the upper-bounded side is a percentile and the bound is not a timing from the same run
    (`p95 < P95_BUDGET_MS`, `metrics.p99 < budget.p99`).
It does not flag `p99 <= max` (one sample set's order, which load does not change), a lower bound
(load only makes a timing longer), or a plain `elapsed < TIMEOUT` (a deadline: fix 6, and cmux's
`detect_assert_on_duration`). A name it cannot follow (a parameter, a match binding) is read by its
words, as before: `latency`, `busy`, `*_ms` are timings, `p95`, `median` percentiles, `budget`,
`limit`, `timeout` and SCREAMING_CASE bounds.

Skipped: `#[ignore]`, `#[tokio::test(start_paused = true)]` (tokio's paused clock), a `// not
wall-clock: <why>` comment on the line above the assert, and a test nextest runs alone or not at all:
the first override in a profile (ci and default; the default profile's overrides apply to ci too)
whose filter matches it sets `threads-required = 'num-test-threads'` with no `platform`, or the
profile's `default-filter` leaves it out. Filters are read with tomllib (any TOML quoting) and a
filterset parser (test(), binary_id(), binary(), package(), kind(), all(), none(); = ~ / # matchers;
not ! and & - or | +), matched against the test's nextest name (module path::fn) and binary id from
its crate's Cargo.toml.
"""

from __future__ import annotations

import fnmatch
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


# ---------------------------------------------------------------------------------------------
# Tokenizer


@dataclass(frozen=True)
class Tok:
    kind: str  # ident, lit, punct, lifetime
    text: str
    line: int
    start: int
    end: int


PUNCTS = (
    ">>=", "<<=", "...", "..=",
    "::", "->", "=>", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=",
    "<<", ">>", "..",
)
# Plain character runs, no backtracking: tokenize's hot loop in C.
WS_RUN = re.compile(r"\s+")
IDENT_RUN = re.compile(r"\w+")
PUNCT_BY_FIRST: dict[str, tuple[str, ...]] = {}
for _p in PUNCTS:
    PUNCT_BY_FIRST[_p[0]] = (*PUNCT_BY_FIRST.get(_p[0], ()), _p)


def _ident_start(c: str) -> bool:
    return c.isalpha() or c == "_"


def _ident_char(c: str) -> bool:
    return c.isalnum() or c == "_"


def tokenize(src: str) -> tuple[list[Tok], dict[int, str]]:
    """Rust tokens and the line comments (line -> text). Lenient: never raises on odd input."""
    toks: list[Tok] = []
    comments: dict[int, str] = {}
    i, n, line = 0, len(src), 1

    def scan_string(j: int) -> int:
        # j at the opening quote; returns the index after the closing quote.
        nonlocal line
        j += 1
        while j < n:
            c = src[j]
            if c == "\\":
                if j + 1 < n and src[j + 1] == "\n":
                    line += 1
                j += 2
                continue
            if c == "\n":
                line += 1
            if c == '"':
                return j + 1
            j += 1
        return n

    def scan_raw(j: int) -> int:
        # j at the r; returns the index after the closing quote and hashes.
        nonlocal line
        j += 1
        hashes = 0
        while j < n and src[j] == "#":
            hashes += 1
            j += 1
        if j >= n or src[j] != '"':
            return -1
        close = '"' + "#" * hashes
        end = src.find(close, j + 1)
        end = n if end < 0 else end + len(close)
        line += src.count("\n", j, end)
        return end

    while i < n:
        c = src[i]
        if c.isspace():
            j = WS_RUN.match(src, i).end()
            line += src.count("\n", i, j)
            i = j
            continue
        if c == "/" and src.startswith("//", i):
            end = src.find("\n", i)
            end = n if end < 0 else end
            comments[line] = comments.get(line, "") + src[i:end]
            i = end
            continue
        if c == "/" and src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    if src[j] == "\n":
                        line += 1
                    j += 1
            i = j
            continue
        start_line = line
        # Prefixed literals: b"", b'', r"", r#""#, br"", c"", cr"".
        if c in "brc":
            k = i
            if src.startswith(("br", "cr"), i):
                k = i + 1
            if src[k] == "r" and k + 1 < n and src[k + 1] in '"#':
                end = scan_raw(k)
                if end > 0:
                    toks.append(Tok("lit", src[i:end], start_line, i, end))
                    i = end
                    continue
            if c in "bc" and k == i and i + 1 < n and src[i + 1] == '"':
                end = scan_string(i + 1)
                toks.append(Tok("lit", src[i:end], start_line, i, end))
                i = end
                continue
            if c == "b" and i + 1 < n and src[i + 1] == "'":
                j = i + 2
                if j < n and src[j] == "\\":
                    j += 2
                while j < n and src[j] != "'" and src[j] != "\n":
                    j += 1
                toks.append(Tok("lit", src[i : j + 1], start_line, i, j + 1))
                i = j + 1
                continue
        if src.startswith("r#", i) and i + 2 < n and _ident_start(src[i + 2]):
            j = i + 2
            while j < n and _ident_char(src[j]):
                j += 1
            toks.append(Tok("ident", src[i + 2 : j], start_line, i, j))
            i = j
            continue
        if _ident_start(c):
            j = IDENT_RUN.match(src, i).end()
            toks.append(Tok("ident", src[i:j], start_line, i, j))
            i = j
            continue
        if c.isdigit():
            j = i + 1
            hexy = src.startswith(("0x", "0b", "0o"), i)
            while j < n:
                d = src[j]
                if _ident_char(d):
                    j += 1
                elif d in "+-" and not hexy and src[j - 1] in "eE" and j + 1 < n and src[j + 1].isdigit():
                    j += 1
                elif d == "." and j + 1 < n and src[j + 1].isdigit() and "." not in src[i:j]:
                    j += 1
                elif d == "." and not (j + 1 < n and (src[j + 1] == "." or _ident_start(src[j + 1]))) and "." not in src[i:j]:
                    j += 1  # `1.` is a float
                else:
                    break
            toks.append(Tok("lit", src[i:j], start_line, i, j))
            i = j
            continue
        if c == '"':
            end = scan_string(i)
            toks.append(Tok("lit", src[i:end], start_line, i, end))
            i = end
            continue
        if c == "'":
            # A char literal ('a', '\n', '\u{1F600}') or a lifetime / label ('a, 'static).
            if i + 1 < n and src[i + 1] == "\\":
                j = i + 2
                while j < n and src[j] != "'" and src[j] != "\n":
                    j += 1
                toks.append(Tok("lit", src[i : j + 1], start_line, i, j + 1))
                i = j + 1
                continue
            if i + 2 < n and src[i + 2] == "'":
                toks.append(Tok("lit", src[i : i + 3], start_line, i, i + 3))
                i += 3
                continue
            j = i + 1
            while j < n and _ident_char(src[j]):
                j += 1
            toks.append(Tok("lifetime", src[i:j], start_line, i, j))
            i = max(j, i + 1)
            continue
        for p in PUNCT_BY_FIRST.get(c, ()):
            if src.startswith(p, i):
                toks.append(Tok("punct", p, start_line, i, i + len(p)))
                i += len(p)
                break
        else:
            toks.append(Tok("punct", c, start_line, i, i + 1))
            i += 1
    return toks, comments


OPEN = {"(": ")", "[": "]", "{": "}"}


def match_close(toks: list[Tok], i: int, hi: int | None = None) -> int:
    """Index of the bracket closing toks[i] (an opener), or the last index when unbalanced."""
    hi = len(toks) if hi is None else hi
    depth = 0
    for k in range(i, hi):
        t = toks[k]
        if t.kind != "punct":
            continue
        if t.text in OPEN:
            depth += 1
        elif t.text in (")", "]", "}"):
            depth -= 1
            if depth == 0:
                return k
    return hi - 1


# ---------------------------------------------------------------------------------------------
# Expressions


@dataclass
class Node:
    op: str  # lit path call method field index unary bin cast tuple array macro struct closure opaque
    lo: int
    hi: int  # token range [lo, hi)
    args: list["Node"] = field(default_factory=list)
    name: str = ""


BINARY_BP = {
    "||": 2, "&&": 3,
    "==": 4, "!=": 4, "<": 4, ">": 4, "<=": 4, ">=": 4,
    "|": 5, "^": 6, "&": 7, "<<": 8, ">>": 8,
    "+": 9, "-": 9, "*": 10, "/": 10, "%": 10,
}
AS_BP = 11
COMPARISONS = ("<", "<=", ">", ">=")
STOP = {",", ";", ")", "]", "}", "=>", "=", "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "<<=", ">>="}
BLOCK_KEYWORDS = {"if", "match", "while", "loop", "for", "unsafe", "async", "const"}


class Parser:
    def __init__(self, toks: list[Tok], lo: int, hi: int):
        self.t, self.i, self.hi = toks, lo, hi

    def peek(self, k: int = 0) -> Tok | None:
        j = self.i + k
        return self.t[j] if j < self.hi else None

    def at(self, text: str, k: int = 0) -> bool:
        tok = self.peek(k)
        return tok is not None and tok.text == text and tok.kind in ("punct", "ident")

    def skip_balanced(self) -> None:
        self.i = match_close(self.t, self.i, self.hi) + 1

    def skip_generics(self) -> None:
        # at '<': skip to the matching '>' (counting '>>' as two).
        depth = 0
        while self.i < self.hi:
            x = self.t[self.i].text
            if x == "<":
                depth += 1
            elif x == "<<":
                depth += 2
            elif x == ">":
                depth -= 1
            elif x == ">>":
                depth -= 2
            elif x == "->":
                pass
            elif x in ("(", "["):
                self.skip_balanced()
                continue
            self.i += 1
            if depth <= 0:
                return

    def expr(self, min_bp: int = 0, no_struct: bool = False) -> Node:
        lo = self.i
        left = self.unary(no_struct)
        while True:
            tok = self.peek()
            if tok is None or tok.kind not in ("punct", "ident") or tok.text in STOP:
                break
            if tok.text == "as" and tok.kind == "ident":
                if AS_BP < min_bp:
                    break
                self.i += 1
                self.skip_type()
                left = Node("cast", lo, self.i, [left])
                continue
            if tok.text in ("..", "..="):
                if min_bp > 1:
                    break
                self.i += 1
                nxt = self.peek()
                args = [left]
                if nxt is not None and not (nxt.text in STOP or (no_struct and nxt.text == "{")):
                    args.append(self.expr(2, no_struct))
                left = Node("range", lo, self.i, args)
                continue
            bp = BINARY_BP.get(tok.text) if tok.kind == "punct" else None
            if bp is None or bp < min_bp:
                break
            self.i += 1
            right = self.expr(bp + 1, no_struct)
            left = Node("bin", lo, self.i, [left, right], tok.text)
        return left

    def skip_type(self) -> None:
        while self.i < self.hi:
            tok = self.t[self.i]
            if tok.kind == "ident" or tok.text in ("::", "&", "*"):
                self.i += 1
            elif tok.text == "<":
                self.skip_generics()
            elif tok.text in ("(", "["):
                self.skip_balanced()
            else:
                return

    def unary(self, no_struct: bool) -> Node:
        lo = self.i
        tok = self.peek()
        if tok is None:
            return Node("opaque", lo, lo)
        if tok.kind == "punct" and tok.text in ("-", "!", "*", "&", "&&"):
            self.i += 1
            if tok.text in ("&", "&&") and self.at("mut"):
                self.i += 1
            inner = self.unary(no_struct)
            return Node("unary", lo, self.i, [inner], tok.text)
        if tok.kind == "punct" and tok.text in ("..", "..="):
            self.i += 1
            args = []
            nxt = self.peek()
            if nxt is not None and nxt.text not in STOP:
                args.append(self.expr(2, no_struct))
            return Node("range", lo, self.i, args)
        return self.postfix(self.primary(no_struct), lo)

    def primary(self, no_struct: bool) -> Node:
        lo = self.i
        tok = self.peek()
        assert tok is not None
        if tok.kind in ("lit", "lifetime"):
            self.i += 1
            if tok.kind == "lifetime" and self.at(":"):  # a label: 'outer: loop { .. }
                self.i += 1
                return self.primary(no_struct)
            return Node("lit", lo, self.i)
        if tok.kind == "punct":
            if tok.text in ("|", "||"):
                return self.closure()
            if tok.text == "(":
                end = match_close(self.t, self.i, self.hi)
                items, trailing = self.list_between(self.i + 1, end)
                self.i = end + 1
                if len(items) == 1 and not trailing:
                    inner = items[0]
                    return Node("paren", lo, self.i, [inner])
                return Node("tuple", lo, self.i, items)
            if tok.text == "[":
                end = match_close(self.t, self.i, self.hi)
                items, _ = self.list_between(self.i + 1, end, repeat_ok=True)
                self.i = end + 1
                return Node("array", lo, self.i, items)
            if tok.text == "{":
                self.skip_balanced()
                return Node("opaque", lo, self.i)
            if tok.text in ("::", "<"):
                return self.path(no_struct)
            self.i += 1
            return Node("opaque", lo, self.i)
        # ident
        if tok.text == "move" and self.peek(1) is not None and self.peek(1).text in ("|", "||"):
            self.i += 1
            return self.closure()
        if tok.text in ("true", "false"):
            self.i += 1
            return Node("lit", lo, self.i)
        if tok.text in BLOCK_KEYWORDS and not (tok.text == "const" and not self.at("{", 1)):
            return self.block_expr()
        if tok.text in ("return", "break", "continue", "yield"):
            self.i = self.hi
            return Node("opaque", lo, self.i)
        return self.path(no_struct)

    def block_expr(self) -> Node:
        lo = self.i
        # if/while/match/for/loop/unsafe/async: skip to the first top-level '{' and over its block,
        # then any `else` chain.
        while self.i < self.hi:
            x = self.t[self.i]
            if x.text == "{" and x.kind == "punct":
                self.skip_balanced()
                if self.at("else"):
                    self.i += 1
                    continue
                break
            if x.text in ("(", "["):
                self.skip_balanced()
                continue
            if x.text in (";",) or (x.text in STOP and x.text not in ("=", "=>")):
                break
            self.i += 1
        return Node("opaque", lo, self.i)

    def closure(self) -> Node:
        lo = self.i
        if self.at("||"):
            self.i += 1
        else:
            self.i += 1
            while self.i < self.hi and not self.at("|"):
                if self.t[self.i].text in ("(", "["):
                    self.skip_balanced()
                else:
                    self.i += 1
            self.i += 1
        if self.at("->"):
            self.i += 1
            self.skip_type()
        body = self.expr(1)
        return Node("closure", lo, self.i, [body])

    def path(self, no_struct: bool) -> Node:
        lo = self.i
        segs: list[str] = []
        if self.at("<"):  # <T as Trait>::f
            self.skip_generics()
        while self.i < self.hi:
            tok = self.t[self.i]
            if tok.kind == "ident":
                segs.append(tok.text)
                self.i += 1
            elif tok.text == "::":
                self.i += 1
                if self.at("<"):
                    self.skip_generics()
                continue
            else:
                break
            if not self.at("::"):
                break
        name = "::".join(segs)
        if self.at("!") and self.peek(1) is not None and self.peek(1).text in OPEN:
            self.i += 1
            open_at = self.i
            self.skip_balanced()
            return Node("macro", lo, self.i, [Node("opaque", open_at, self.i)], name)
        if (
            self.at("{")
            and not no_struct
            and segs
            and segs[-1][:1].isupper()
        ):
            self.skip_balanced()
            return Node("struct", lo, self.i, [], name)
        if not segs:
            self.i = max(self.i, lo + 1)
            return Node("opaque", lo, self.i)
        return Node("path", lo, self.i, [], name)

    def postfix(self, node: Node, lo: int) -> Node:
        while self.i < self.hi:
            tok = self.t[self.i]
            if tok.text == "?" and tok.kind == "punct":
                self.i += 1
                node = Node("try", lo, self.i, [node])
            elif tok.text == "." and tok.kind == "punct":
                nxt = self.peek(1)
                if nxt is None:
                    break
                self.i += 2
                if nxt.kind == "lit":  # tuple field .0 (or .0.1 lexed as a float)
                    node = Node("field", lo, self.i, [node], nxt.text)
                    continue
                if nxt.text == "await":
                    node = Node("try", lo, self.i, [node])
                    continue
                if self.at("::") and self.at("<", 1):
                    self.i += 1
                    self.skip_generics()
                if self.at("("):
                    end = match_close(self.t, self.i, self.hi)
                    args, _ = self.list_between(self.i + 1, end)
                    self.i = end + 1
                    node = Node("method", lo, self.i, [node, *args], nxt.text)
                else:
                    node = Node("field", lo, self.i, [node], nxt.text)
            elif tok.text == "(" and tok.kind == "punct":
                end = match_close(self.t, self.i, self.hi)
                args, _ = self.list_between(self.i + 1, end)
                self.i = end + 1
                node = Node("call", lo, self.i, [node, *args])
            elif tok.text == "[" and tok.kind == "punct":
                end = match_close(self.t, self.i, self.hi)
                sub = Parser(self.t, self.i + 1, end)
                idx = sub.expr() if end > self.i + 1 else Node("opaque", self.i, self.i)
                self.i = end + 1
                node = Node("index", lo, self.i, [node, idx])
            else:
                break
        return node

    def list_between(self, lo: int, hi: int, repeat_ok: bool = False) -> tuple[list[Node], bool]:
        """Comma-separated expressions in [lo, hi); True when a trailing comma ends the list."""
        sub = Parser(self.t, lo, hi)
        items: list[Node] = []
        trailing = False
        while sub.i < hi:
            start = sub.i
            items.append(sub.expr())
            trailing = False
            if sub.i < hi and sub.t[sub.i].text in (",", ";"):
                sub.i += 1
                trailing = True
            elif sub.i < hi:
                sub.i = max(sub.i, start) + 1  # unparsed token: move on
        return items, trailing


def parse_args(toks: list[Tok], lo: int, hi: int) -> list[Node]:
    try:
        return Parser(toks, lo, hi).list_between(lo, hi)[0]
    except (AssertionError, IndexError, RecursionError):
        return []


def parse_expr(toks: list[Tok], lo: int, hi: int, no_struct: bool = False) -> Node:
    try:
        p = Parser(toks, lo, hi)
        return p.expr(0, no_struct)
    except (AssertionError, IndexError, RecursionError):
        return Node("opaque", lo, hi)


# ---------------------------------------------------------------------------------------------
# What an expression holds


CONST, INSTANT, TIMING, PCT, RATIO, OTHER, CLOCKFN = "const", "instant", "timing", "pct", "ratio", "other", "clockfn"
MEASURED = (TIMING, PCT)
RANK = {CONST: 0, OTHER: 1, CLOCKFN: 1, INSTANT: 2, TIMING: 3, PCT: 4, RATIO: 5}


@dataclass(frozen=True)
class Kind:
    base: str
    scaled: bool = False  # scaled by a constant in the expression being judged (`idle * 4`)
    src: frozenset = frozenset()  # where a measurement came from: clock reads, calls, names

    @property
    def measured(self) -> bool:
        return self.base in MEASURED

    def but(self, base: str | None = None, scaled: bool | None = None, src: frozenset | None = None) -> "Kind":
        return Kind(self.base if base is None else base, self.scaled if scaled is None else scaled,
                    self.src if src is None else src)


K_CONST, K_OTHER, K_INSTANT, K_TIMING, K_PCT, K_RATIO = (
    Kind(CONST), Kind(OTHER), Kind(INSTANT), Kind(TIMING), Kind(PCT), Kind(RATIO))


def join(*kinds: Kind) -> Kind:
    best = K_CONST
    src: frozenset = frozenset()
    for k in kinds:
        src |= k.src
        if RANK[k.base] > RANK[best.base] or (k.base == best.base and k.scaled and not best.scaled):
            best = k
    return best.but(src=src)


PCT_WORDS = {"median", "percentile", "percentiles", "quantile"}
BOUND_WORDS = {"budget", "budgets", "bound", "bounds", "limit", "limits", "deadline", "timeout", "allowed",
               "threshold", "ceiling", "cap", "slo"}
TIMING_WORDS = {"elapsed", "took", "latency", "latencies", "wall", "busy", "idle", "loaded", "quiet", "baseline",
                "cold", "warm", "echo", "echoes", "rtt", "duration", "durations", "timing", "timings", "trip"}
UNIT_WORDS = {"us", "ms", "ns", "micros", "millis", "nanos", "secs"}
COUNT_METHODS = {"len", "count", "is_empty", "capacity", "is_some", "is_none", "is_ok", "is_err", "contains"}
SCALE_METHODS = {"mul_f64": "*", "mul_f32": "*", "checked_mul": "*", "saturating_mul": "*",
                 "div_f64": "/", "div_f32": "/", "checked_div": "/", "div_duration_f64": "/", "div_duration_f32": "/"}
SPAN_METHODS = {"elapsed"}
SINCE_METHODS = {"duration_since", "saturating_duration_since", "checked_duration_since"}


def words(name: str) -> list[str]:
    return [w for w in name.lower().split("_") if w]


def is_screaming(name: str) -> bool:
    return any(c.isalpha() for c in name) and name == name.upper()


def is_pct_word(w: str) -> bool:
    return w in PCT_WORDS or (len(w) >= 3 and w[0] == "p" and w[1:].isdigit())


def name_kind(name: str) -> Kind:
    """What a name holds when its binding can't be followed: read by its words."""
    if is_screaming(name):
        return K_CONST
    ws = words(name)
    if any(w in BOUND_WORDS for w in ws):
        return K_CONST
    if any(is_pct_word(w) for w in ws):
        return K_PCT
    if any(w in TIMING_WORDS for w in ws) or (len(ws) > 1 and ws[-1] in UNIT_WORDS) or ws in (["us"], ["ms"], ["ns"]):
        return K_TIMING
    return K_OTHER


@dataclass
class Scope:
    env: dict[str, Kind]
    consts: set[str]
    clock_fns: dict
    toks: list[Tok]


def reads_clock(toks: list[Tok], lo: int, hi: int) -> bool:
    for k in range(lo, hi):
        x = toks[k].text
        if x == "elapsed" and k > 0 and toks[k - 1].text == ".":
            return True
        if x in ("Instant", "SystemTime") and k + 2 < hi and toks[k + 1].text == "::" and toks[k + 2].text == "now":
            return True
        if x in SINCE_METHODS:
            return True
    return False


def arith(op: str, a: Kind, b: Kind) -> Kind:
    src = a.src | b.src
    if op in ("*", "/") and a.base == RATIO and not b.measured:
        return a.but(src=src)
    if op == "*" and b.base == RATIO and not a.measured:
        return b.but(src=src)
    if op == "/" and a.measured and b.measured:
        return K_RATIO.but(src=src)
    if op == "*":
        if a.measured and not b.measured:
            return a.but(scaled=True, src=src)
        if b.measured and not a.measured:
            return b.but(scaled=True, src=src)
        if a.measured and b.measured:
            return K_OTHER
        return K_CONST if a.base == CONST and b.base == CONST else K_OTHER
    if op == "/":
        if a.measured:
            return a.but(scaled=True, src=src)
        return K_CONST if a.base == CONST and b.base == CONST else K_OTHER
    if op in ("+", "-"):
        if a.base == INSTANT and b.base == INSTANT:
            return K_TIMING.but(src=src) if op == "-" else K_OTHER
        if a.base == INSTANT or b.base == INSTANT:
            return K_INSTANT.but(src=src)
        if a.measured or b.measured:
            m = join(a, b)
            return m.but(scaled=a.scaled or b.scaled)
        return K_CONST if a.base == CONST and b.base == CONST else K_OTHER
    if op == "%":
        return a if a.base == CONST else K_OTHER
    return K_OTHER


def named(name: str, key: str) -> Kind:
    k = name_kind(name)
    return k.but(src=frozenset({key})) if k.measured else k


def here(node: Node) -> frozenset:
    return frozenset({f"at:{node.lo}"})


def kind_of(node: Node, sc: Scope) -> Kind:
    op = node.op
    if op == "lit":
        return K_CONST
    if op in ("paren", "cast", "try"):
        return kind_of(node.args[0], sc) if node.args else K_OTHER
    if op == "path":
        segs = node.name.split("::")
        last = segs[-1]
        if len(segs) == 1:
            if last in sc.env:
                return sc.env[last]
            if last in sc.consts or last in ("true", "false"):
                return K_CONST
            return named(last, f"name:{last}")
        if is_screaming(last) or last in sc.consts:
            return K_CONST
        return named(last, f"name:{node.name}") if last[:1].islower() else K_OTHER
    if op == "unary":
        inner = kind_of(node.args[0], sc)
        return K_OTHER if node.name == "!" else inner
    if op == "bin":
        if node.name in BINARY_BP and BINARY_BP[node.name] <= 4:
            return K_OTHER  # a bool
        return arith(node.name, kind_of(node.args[0], sc), kind_of(node.args[1], sc))
    if op in ("tuple", "array"):
        return join(*(kind_of(a, sc) for a in node.args)) if node.args else K_OTHER
    if op == "index":
        return kind_of(node.args[0], sc)
    if op == "field":
        base = node.args[0]
        bk = kind_of(base, sc)
        fname = node.name
        if bk.measured or bk.base == RATIO:
            if any(is_pct_word(w) for w in words(fname)):
                return bk.but(base=PCT)
            return bk
        base_name = sc_text(sc, base)
        if any(w in BOUND_WORDS for w in words(base_name.replace(".", "_"))) or bk.base == CONST:
            return K_CONST
        return named(fname, f"name:{base_name}")
    if op == "method":
        recv = kind_of(node.args[0], sc)
        args = [kind_of(a, sc) for a in node.args[1:]]
        m = node.name
        ws = words(m)
        if m in SPAN_METHODS:
            return K_TIMING.but(src=recv.src if recv.base == INSTANT and recv.src else here(node))
        if m in SINCE_METHODS:
            src = recv.src.union(*(a.src for a in args))
            return K_TIMING.but(src=src or here(node))
        if m in COUNT_METHODS:
            return K_OTHER
        if any(is_pct_word(w) for w in ws):
            if recv.measured or recv.base == OTHER:
                return K_PCT.but(src=recv.src or here(node))
            return recv
        if m in SCALE_METHODS and args:
            return arith(SCALE_METHODS[m], recv, args[0])
        if m in ("max", "min", "saturating_sub", "checked_sub", "abs_diff", "saturating_add", "checked_add") and args:
            return join(recv, args[0]) if recv.base != INSTANT else recv
        if recv.base == CLOCKFN and m in ("call", "call_mut", "call_once"):
            return K_TIMING.but(src=here(node))
        return recv
    if op == "call":
        callee = node.args[0]
        args = [kind_of(a, sc) for a in node.args[1:]]
        cname = callee.name if callee.op == "path" else ""
        segs = cname.split("::") if cname else []
        last = segs[-1] if segs else ""
        measured_args = [a for a in args if a.measured or a.base == RATIO]
        if len(segs) >= 2 and segs[-2] in ("Instant", "SystemTime") and last == "now":
            return K_INSTANT.but(src=here(node))
        if len(segs) >= 2 and segs[-2] == "Duration":
            return join(*measured_args) if measured_args else K_CONST
        if callee.op == "path" and len(segs) == 1 and cname in sc.env:
            v = sc.env[cname]
            return K_TIMING.but(src=here(node)) if v.base == CLOCKFN else (v if v.base != OTHER else K_OTHER)
        if last and any(is_pct_word(w) for w in words(last)):
            src = frozenset().union(*(a.src for a in measured_args))
            return K_PCT.but(src=src or here(node))
        if last in sc.clock_fns:
            flags = sc.clock_fns[last]
            return K_TIMING.but(src=here(node)) if flags is None or all(flags) else K_OTHER
        if last in COUNT_METHODS:
            return K_OTHER
        if segs and segs[-1][:1].isupper():  # a constructor: Some(x), Ok(x), Stats::new(..) keep the measure
            if measured_args:
                return join(*measured_args)
            return K_CONST if args and all(a.base == CONST for a in args) else K_OTHER
        if measured_args:
            return join(*measured_args)
        if args and all(a.base == CONST for a in args):
            return K_CONST  # test_timeout(Duration::from_secs(5)): a bound built from constants
        if last and name_kind(last) == K_TIMING and not is_screaming(last):
            return K_TIMING.but(src=frozenset({f"name:{last}"}))
        return K_OTHER
    if op == "closure":
        return Kind(CLOCKFN) if reads_clock(sc.toks, node.lo, node.hi) else K_OTHER
    return K_OTHER


def sc_text(sc: Scope, node: Node) -> str:
    return "".join(t.text for t in sc.toks[node.lo : node.hi])


def comparisons(node: Node) -> list[Node]:
    if node.op == "paren" and node.args:
        return comparisons(node.args[0])
    if node.op == "unary" and node.name == "!" and node.args:
        return comparisons(node.args[0])
    if node.op == "bin" and node.name in ("&&", "||"):
        return comparisons(node.args[0]) + comparisons(node.args[1])
    if node.op == "bin" and node.name in COMPARISONS:
        return [node]
    return []


def judge(cmp: Node, sc: Scope) -> str | None:
    lk, rk = kind_of(cmp.args[0], sc), kind_of(cmp.args[1], sc)
    if lk.base == RATIO or rk.base == RATIO:
        return "ratio of two timings"
    if lk.measured and rk.measured:
        if lk.scaled or rk.scaled:
            return "ratio of two timings"
        if lk.src & rk.src:
            return None  # p99 <= max: one sample set's own order, which load does not change
        if any(x.startswith("at:") for x in lk.src) and any(x.startswith("at:") for x in rk.src):
            return "ratio of two timings"  # two timings taken apart (`handle_us <= json_us`): a ratio against 1
        return None  # a name read by its words (`since_ms`, `updated_at_ms`) may be a timestamp
    upper = lk if cmp.name in ("<", "<=") else rk
    if upper.measured and upper.base == PCT:
        return "percentile bound"
    return None


# ---------------------------------------------------------------------------------------------
# Items: test functions, consts, local helpers


ASSERT_MACROS = {
    "assert", "debug_assert", "assert_eq", "assert_ne", "debug_assert_eq", "debug_assert_ne",
    "prop_assert", "prop_assert_eq", "prop_assert_ne",
}
TEST_ATTRS = {"test", "rstest", "test_case"}
QUALIFIERS = {"pub", "async", "unsafe", "const", "extern", "crate", "super", "self", "in", "default"}


@dataclass
class Fn:
    name: str
    attrs: list[list[Tok]]
    mods: list[str]
    body_lo: int
    body_hi: int
    ret: list[Tok]
    line: int

    def attr_paths(self) -> list[str]:
        out = []
        for a in self.attrs:
            segs = []
            for t in a:
                if t.kind == "ident":
                    segs.append(t.text)
                elif t.text != "::":
                    break
            out.append("::".join(segs))
        return out

    @property
    def is_test(self) -> bool:
        return any(p.split("::")[-1] in TEST_ATTRS for p in self.attr_paths())

    @property
    def ignored(self) -> bool:
        return "ignore" in self.attr_paths()

    @property
    def paused(self) -> bool:
        return any(any(t.text == "start_paused" for t in a) for a in self.attrs)


def items(toks: list[Tok]) -> tuple[list[Fn], set[str]]:
    fns: list[Fn] = []
    consts: set[str] = set()
    mods: list[tuple[str, int]] = []
    depth = 0
    pending: list[list[Tok]] = []
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if t.text == "#" and i + 1 < n and toks[i + 1].text == "[":
            end = match_close(toks, i + 1)
            pending.append(toks[i + 2 : end])
            i = end + 1
            continue
        if t.text == "#" and i + 2 < n and toks[i + 1].text == "!" and toks[i + 2].text == "[":
            i = match_close(toks, i + 2) + 1
            continue
        if t.kind == "ident" and t.text in ("const", "static") and i + 2 < n and toks[i + 1].kind == "ident":
            j = i + 1
            if toks[j].text == "mut":
                j += 1
            if j + 1 < n and toks[j + 1].text == ":":
                consts.add(toks[j].text)
        if t.kind == "ident" and t.text == "mod" and i + 2 < n and toks[i + 1].kind == "ident" and toks[i + 2].text == "{":
            depth += 1
            mods.append((toks[i + 1].text, depth))
            pending = []
            i += 3
            continue
        if t.kind == "ident" and t.text == "fn" and i + 1 < n and toks[i + 1].kind == "ident":
            name = toks[i + 1].text
            j = i + 2
            ret: list[Tok] = []
            in_ret = False
            while j < n and toks[j].text not in ("{", ";"):
                if toks[j].text in ("(", "["):
                    end = match_close(toks, j)
                    if in_ret:
                        ret.extend(toks[j : end + 1])
                    j = end + 1
                    continue
                if toks[j].text == "->":
                    in_ret = True
                elif toks[j].text == "where":
                    in_ret = False
                elif in_ret:
                    ret.append(toks[j])
                j += 1
            if j < n and toks[j].text == "{":
                end = match_close(toks, j)
                fns.append(Fn(name, pending, [m for m, _ in mods], j + 1, end, ret, t.line))
                depth += 1
                pending = []
                i = j + 1
                continue
            pending = []
            i = j + 1
            continue
        if t.text == "{":
            depth += 1
            pending = []
        elif t.text == "}":
            depth -= 1
            while mods and mods[-1][1] > depth:
                mods.pop()
            pending = []
        elif t.text == ";" or (t.kind == "ident" and t.text not in QUALIFIERS) or t.kind == "lit" and not t.text.startswith('"'):
            pending = []
        i += 1
    return fns, consts


def clock_fns(fns: list[Fn], toks: list[Tok]) -> dict[str, tuple[bool, ...] | None]:
    """Local fns whose value is a timing: None when all of it is, else which tuple positions are.

    A fn that reads the clock and returns a Duration (`-> Duration`, `-> Vec<Duration>`, `-> (u64,
    Duration)`). One that builds a Duration from constants (`fn test_duration(d) -> Duration`, a scaled
    bound) is not, and a number from the clock (`fn now_ms() -> u64`) is a timestamp: two of them
    compare in an order load keeps."""
    out: dict[str, tuple[bool, ...] | None] = {}
    for f in fns:
        if f.is_test:
            continue
        ret = [t.text for t in f.ret]
        if "Duration" in ret and reads_clock(toks, f.body_lo, f.body_hi):
            if ret[:1] == ["("] and ret[-1:] == [")"]:
                parts, depth, cur = [], 0, []
                for x in ret[1:-1]:
                    if x in ("(", "[", "<"):
                        depth += 1
                    elif x in (")", "]", ">"):
                        depth -= 1
                    if x == "," and depth == 0:
                        parts.append(cur)
                        cur = []
                    else:
                        cur.append(x)
                parts.append(cur)
                out[f.name] = tuple("Duration" in part for part in parts if part)
            else:
                out[f.name] = None
    return out


# ---------------------------------------------------------------------------------------------
# A test body: follow its bindings, judge its asserts


def pattern_names(toks: list[Tok], lo: int, hi: int) -> list[tuple[str, list[int]]]:
    """Names a pattern binds with the tuple positions that lead to each: (a, (b, c)) -> a [0], b [1, 0]."""
    out: list[tuple[str, list[int]]] = []
    path: list[int] = []
    stack: list[str] = []
    k = lo
    while k < hi:
        t = toks[k]
        x = t.text
        if x in ("(", "["):
            stack.append(x)
            path.append(0)
        elif x in (")", "]"):
            if stack:
                stack.pop()
                path.pop()
        elif x == "{":  # Struct { a, b: c, .. }: every name in it, no position
            end = match_close(toks, k, hi)
            for j in range(k + 1, end):
                tj = toks[j]
                if tj.kind == "ident" and tj.text not in ("mut", "ref") and not (j + 1 < end and toks[j + 1].text in (":", "::", "(", "{")):
                    out.append((tj.text, [-1]))
            k = end
        elif x == ",":
            if path:
                path[-1] += 1
        elif t.kind == "ident" and x not in ("mut", "ref", "_") and x[:1].islower() and not (k + 1 < hi and toks[k + 1].text in ("::", "(", "{")):
            out.append((x, list(path)))
        k += 1
    return out


def bind(sc: Scope, toks: list[Tok], plo: int, phi: int, value: Node | None, vkind: Kind) -> None:
    for name, pos in pattern_names(toks, plo, phi):
        node = value
        k = vkind
        if node is not None and pos and pos[0] != -1:
            for depth, p in enumerate(pos):
                while node is not None and node.op in ("paren", "try"):
                    node = node.args[0]
                if node is not None and node.op == "tuple" and p < len(node.args):
                    node = node.args[p]
                    continue
                flags = tuple_fn_flags(node, sc)
                if flags is not None and depth == len(pos) - 1:
                    k = K_TIMING.but(src=here(node)) if p < len(flags) and flags[p] else K_OTHER
                node = None
                break
            if node is not None:
                k = kind_of(node, sc)
        # A name holds a measurement in its own unit: `let json_us = elapsed * 1e6 / n` is not scaled
        # against anything; only a scale in the compared expression is.
        k = k.but(scaled=False)
        if k.measured and any(is_pct_word(w) for w in words(name)):
            k = k.but(base=PCT)
        sc.env[name] = k


def tuple_fn_flags(node: Node | None, sc: Scope) -> tuple[bool, ...] | None:
    if node is None or node.op != "call" or node.args[0].op != "path":
        return None
    flags = sc.clock_fns.get(node.args[0].name.split("::")[-1], None)
    return flags if isinstance(flags, tuple) else None


def find_top(toks: list[Tok], lo: int, hi: int, texts: tuple[str, ...]) -> int:
    k = lo
    while k < hi:
        x = toks[k].text
        if x in texts and toks[k].kind in ("punct", "ident"):
            return k
        if x in OPEN and toks[k].kind == "punct":
            k = match_close(toks, k, hi) + 1
            continue
        k += 1
    return hi


PUSHES = {"push": -1, "push_back": -1, "push_front": -1, "insert": -1, "extend": -1, "append": -1, "send": -1}


def scan_body(f: Fn, toks: list[Tok], comments: dict[int, str], sc: Scope) -> list[tuple[int, str, str]]:
    found: list[tuple[int, str, str]] = []
    i, hi = f.body_lo, f.body_hi
    while i < hi:
        t = toks[i]
        nxt = toks[i + 1] if i + 1 < hi else None
        if t.kind == "ident" and t.text == "let":
            stmt_end = find_top(toks, i + 1, hi, (";",))
            eq = find_top(toks, i + 1, stmt_end, ("=",))
            colon = find_top(toks, i + 1, eq, (":",))
            if eq < stmt_end:
                els = find_top(toks, eq + 1, stmt_end, ("else",))
                value = parse_expr(toks, eq + 1, els)
                bind(sc, toks, i + 1, colon, value, kind_of(value, sc))
                i = eq + 1
            else:
                bind(sc, toks, i + 1, colon, None, K_OTHER)
                i = stmt_end
            continue
        if t.kind == "ident" and t.text == "for" and nxt is not None and nxt.text != "<":
            in_at = find_top(toks, i + 1, hi, ("in",))
            body = find_top(toks, in_at + 1, hi, ("{",))
            if in_at < hi and body < hi:
                value = parse_expr(toks, in_at + 1, body, no_struct=True)
                bind(sc, toks, i + 1, in_at, None, kind_of(value, sc))
                i = in_at + 1
                continue
        if (
            t.kind == "ident"
            and t.text in ASSERT_MACROS
            and nxt is not None
            and nxt.text == "!"
            and i + 2 < hi
            and toks[i + 2].text in OPEN
        ):
            end = match_close(toks, i + 2, hi)
            args = parse_args(toks, i + 3, end)
            conds = args[:1] if t.text in ("assert", "debug_assert", "prop_assert") else args[:2]
            if "not wall-clock:" not in comments.get(t.line - 1, ""):
                for cond in conds:
                    for cmp in comparisons(cond):
                        kind = judge(cmp, sc)
                        if kind:
                            found.append((toks[cmp.lo].line, kind, source_of(toks, cmp)))
            i = end + 1
            continue
        if t.kind == "ident" and nxt is not None and nxt.kind == "punct" and nxt.text in ("=", "+=", "-=", "*=", "/=") and not (
            i > 0 and toks[i - 1].text in (".", "::")
        ):
            stmt_end = find_top(toks, i + 2, hi, (";", ","))
            value = parse_expr(toks, i + 2, stmt_end)
            vk = kind_of(value, sc)
            if nxt.text == "=":
                sc.env[t.text] = vk
            else:
                old = sc.env.get(t.text, name_kind(t.text))
                sc.env[t.text] = arith(nxt.text[0], old, vk)
            i += 2
            continue
        if (
            t.kind == "ident"
            and nxt is not None
            and nxt.text == "."
            and i + 3 < hi
            and toks[i + 2].text in PUSHES
            and toks[i + 3].text == "("
            and not (i > 0 and toks[i - 1].text in (".", "::"))
        ):
            end = match_close(toks, i + 3, hi)
            args = parse_args(toks, i + 4, end)
            if args:
                pushed = kind_of(args[-1], sc)
                if toks[i + 2].text in ("extend", "append"):
                    pushed = pushed if pushed.base != OTHER else K_OTHER
                sc.env[t.text] = join(sc.env.get(t.text, K_CONST), pushed)
            i += 4
            continue
        i += 1
    return found


def source_of(toks: list[Tok], node: Node) -> str:
    if node.hi <= node.lo:
        return ""
    return " ".join(SRC_HOLDER[0][toks[node.lo].start : toks[node.hi - 1].end].split())


SRC_HOLDER = [""]


@dataclass
class TestId:
    name: str  # nextest's test name: module path::fn
    binary_id: str | None = None
    binary: str | None = None
    package: str | None = None
    kind: str | None = None


def scan_text(text: str, rel: str, runs_beside_others=None, ident=None) -> list[str]:
    """Findings in one file's text. runs_beside_others(TestId) -> bool; ident(fn_mods, name) -> TestId."""
    if "test" not in text or not any(w in text for w in ("Instant", "elapsed", "SystemTime", "Duration", "duration_since")):
        return []
    SRC_HOLDER[0] = text
    toks, comments = tokenize(text)
    if not any(t.text in ("Instant", "elapsed", "SystemTime", "Duration") or t.text in SINCE_METHODS for t in toks):
        return []
    fns, consts = items(toks)
    helpers = clock_fns(fns, toks)
    found = []
    for f in fns:
        if not f.is_test or f.ignored or f.paused:
            continue
        tid = ident(f.mods, f.name) if ident else TestId("::".join([*f.mods, f.name]))
        if runs_beside_others is not None and not runs_beside_others(tid):
            continue
        sc = Scope({}, consts, helpers, toks)
        for line, kind, expr in scan_body(f, toks, comments, sc):
            found.append(f"{rel}:{line}: {kind} in default-run test `{f.name}`: {expr}")
    return found


# ---------------------------------------------------------------------------------------------
# nextest: which tests run alone or not at all


class FilterError(ValueError):
    pass


@dataclass
class FNode:
    op: str  # fn and or not diff
    args: list["FNode"] = field(default_factory=list)
    func: str = ""
    matcher: str = ""  # = ~ # /
    value: str = ""


DEFAULT_MATCHER = {"test": "~", "binary": "~", "package": "#", "binary_id": "#", "deps": "#", "rdeps": "#",
                   "kind": "=", "platform": "="}


def parse_filter(text: str) -> FNode:
    toks: list[tuple[str, str]] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c in "()&|+-!":
            toks.append(("op", c))
            i += 1
        elif c.isalpha() or c == "_":
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            word = text[i:j]
            k = j
            while k < n and text[k].isspace():
                k += 1
            if word not in ("and", "or", "not") and k < n and text[k] == "(":
                k += 1
                while k < n and text[k].isspace():
                    k += 1
                arg_start = k
                if k < n and text[k] == "/":
                    k += 1
                    while k < n and text[k] != "/":
                        k += 2 if text[k] == "\\" else 1
                    k += 1
                while k < n and text[k] != ")":
                    k += 2 if text[k] == "\\" else 1
                if k >= n:
                    raise FilterError(f"unclosed {word}( in {text!r}")
                toks.append(("fn", word + "\0" + text[arg_start:k].strip()))
                i = k + 1
            else:
                toks.append(("op", word))
                i = j
        else:
            raise FilterError(f"unexpected {c!r} in {text!r}")
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        pos[0] += 1
        return toks[pos[0] - 1]

    def or_expr():
        left = and_expr()
        while peek() is not None and peek()[1] in ("|", "or", "+"):
            take()
            left = FNode("or", [left, and_expr()])
        return left

    def and_expr():
        left = unary()
        while peek() is not None and peek()[1] in ("&", "and", "-"):
            op = take()[1]
            right = unary()
            left = FNode("diff" if op == "-" else "and", [left, right])
        return left

    def unary():
        tok = peek()
        if tok is None:
            raise FilterError(f"filter ends early: {text!r}")
        if tok[1] in ("!", "not"):
            take()
            return FNode("not", [unary()])
        if tok[1] == "(":
            take()
            inner = or_expr()
            if peek() is None or peek()[1] != ")":
                raise FilterError(f"unclosed ( in {text!r}")
            take()
            return inner
        if tok[0] == "fn":
            take()
            func, arg = tok[1].split("\0", 1)
            if func in ("all", "none"):
                return FNode("fn", func=func)
            if func not in DEFAULT_MATCHER:
                return FNode("fn", func=func, value=arg)
            matcher = DEFAULT_MATCHER[func]
            if arg[:1] in ("=", "~", "#"):
                matcher, arg = arg[0], arg[1:]
            elif arg[:1] == "/" and arg.endswith("/") and len(arg) >= 2:
                matcher, arg = "/", arg[1:-1]
            return FNode("fn", func=func, matcher=matcher, value=arg.replace("\\)", ")").replace("\\,", ","))
        raise FilterError(f"unexpected {tok[1]!r} in {text!r}")

    tree = or_expr()
    if peek() is not None:
        raise FilterError(f"unexpected {peek()[1]!r} in {text!r}")
    return tree


def match_value(matcher: str, pattern: str, value: str) -> bool:
    if matcher == "=":
        return value == pattern
    if matcher == "~":
        return pattern in value
    if matcher == "#":
        return fnmatch.fnmatchcase(value, pattern)
    try:
        return re.search(pattern, value) is not None
    except re.error:
        return False


def eval_filter(node: FNode, t: TestId) -> bool | None:
    """True, False, or None when the filter asks about something a source scan can't know."""
    if node.op == "not":
        v = eval_filter(node.args[0], t)
        return None if v is None else not v
    if node.op in ("and", "diff"):
        a = eval_filter(node.args[0], t)
        b = eval_filter(node.args[1], t)
        if node.op == "diff":
            b = None if b is None else not b
        if a is False or b is False:
            return False
        return True if a is True and b is True else None
    if node.op == "or":
        a, b = eval_filter(node.args[0], t), eval_filter(node.args[1], t)
        if a is True or b is True:
            return True
        return False if a is False and b is False else None
    f = node.func
    if f == "all":
        return True
    if f == "none":
        return False
    value = {"test": t.name, "binary_id": t.binary_id, "binary": t.binary, "package": t.package, "kind": t.kind}.get(f)
    if value is None:
        return None
    return match_value(node.matcher, node.value, value)


@dataclass
class Override:
    filter: FNode | None
    platform: str | None
    threads_required: object


@dataclass
class Profile:
    overrides: list[Override]
    default_filter: FNode | None
    test_threads: object


def load_nextest(path: Path) -> dict[str, Profile]:
    data = tomllib.loads(path.read_text())
    profiles: dict[str, Profile] = {}
    for name, body in (data.get("profile") or {}).items():
        if not isinstance(body, dict):
            continue
        ovs = []
        for o in body.get("overrides") or []:
            flt = o.get("filter")
            ovs.append(Override(parse_filter(flt) if isinstance(flt, str) else None, o.get("platform"), o.get("threads-required")))
        df = body.get("default-filter")
        profiles[name] = Profile(ovs, parse_filter(df) if isinstance(df, str) else None, body.get("test-threads"))
    return profiles


def runs_beside_others(profiles: dict[str, Profile], t: TestId) -> bool:
    """False when every profile CI uses (ci and default) runs T alone or leaves it out."""
    default = profiles.get("default", Profile([], None, None))
    names = [p for p in ("default", "ci") if p in profiles] or ["default"]
    for name in names:
        prof = profiles.get(name, default)
        overrides = prof.overrides + (default.overrides if name != "default" else [])
        df = prof.default_filter if prof.default_filter is not None else default.default_filter
        if df is not None and eval_filter(df, t) is False:
            continue
        threads = prof.test_threads if prof.test_threads is not None else default.test_threads
        if threads == 1:
            continue
        alone = False
        for o in overrides:
            if o.threads_required is None:
                continue
            hit = True if o.filter is None else eval_filter(o.filter, t)
            if hit is None:
                break  # can't tell: count it as run beside others
            if hit:
                alone = o.platform is None and o.threads_required == "num-test-threads"
                break
        if not alone:
            return True
    return False


# ---------------------------------------------------------------------------------------------
# Files: crate, binary and module path


def crate_of(path: Path, stop: Path, cache: dict) -> tuple[Path, str, str] | None:
    """(crate dir, package name, lib name) of the nearest Cargo.toml with a [package]."""
    for d in path.parents:
        if d in cache:
            return cache[d]
        toml = d / "Cargo.toml"
        if toml.is_file():
            try:
                data = tomllib.loads(toml.read_text())
            except (OSError, tomllib.TOMLDecodeError):
                data = {}
            pkg = (data.get("package") or {}).get("name")
            if isinstance(pkg, str):
                lib = (data.get("lib") or {}).get("name") or pkg.replace("-", "_")
                cache[d] = (d, pkg, lib)
                return cache[d]
        if d == stop or d == d.parent:
            break
    return None


def test_ident(path: Path, checkout: Path, cache: dict):
    """A function (inline mods, fn name) -> TestId for the file, or None for a file nextest doesn't run."""
    crate = crate_of(path, checkout, cache)
    if crate is None:
        return lambda mods, name: TestId("::".join([*mods, name]))
    root, pkg, lib = crate
    parts = list(path.relative_to(root).parts)
    stem = [p[:-3] if p.endswith(".rs") else p for p in parts]
    if parts[0] in ("benches", "examples"):
        return None
    if parts[0] == "tests" and len(parts) >= 2:
        binary = stem[1]
        file_mods = [m for m in stem[2:] if m not in ("main", "mod")]
        bid, kind = f"{pkg}::{binary}", "test"
    elif parts[:2] == ["src", "bin"] and len(parts) >= 3:
        binary = stem[2]
        file_mods = [m for m in stem[3:] if m not in ("main", "mod")]
        bid, kind = f"{pkg}::bin/{binary}", "bin"
    elif parts == ["src", "main.rs"]:
        binary, file_mods, bid, kind = pkg, [], f"{pkg}::bin/{pkg}", "bin"
    else:
        binary = lib
        file_mods = [m for m in stem[1:] if m not in ("lib", "mod")] if parts[0] == "src" else stem
        bid, kind = pkg, "lib"
    return lambda mods, name: TestId("::".join([*file_mods, *mods, name]), bid, binary, pkg, kind)


def nextest_for(path: Path, checkout: Path, cache: dict) -> dict[str, Profile] | None:
    for d in path.parents:
        key = ("nextest", d)
        if key in cache:
            return cache[key]
        cfg = d / ".config" / "nextest.toml"
        if cfg.is_file():
            cache[key] = load_nextest(cfg)
            return cache[key]
        if d == checkout or d == d.parent:
            break
    return None


# ---------------------------------------------------------------------------------------------
# Self-test and CLI


SELF_TEST = """
use std::time::{Duration, Instant};

fn helper() -> Duration { let t = Instant::now(); t.elapsed() }

#[test]
fn ratio_in_default_run() {
    let (busy, idle) = (helper(), helper());
    assert!(busy < idle * 4, "busy {busy:?}");
}

#[test]
fn percentile_in_default_run() {
    let p95 = helper();
    assert!(p95 < BUDGET_MS, "p95");
}

#[test]
fn percentile_against_a_budget_field() {
    let metrics = measure(vec![helper()]);
    assert!(metrics.p95 < budget.p95, "p95");
}

#[test]
#[ignore = "own run"]
fn ratio_in_own_run() {
    let (busy, idle) = (helper(), helper());
    assert!(busy < idle * 4);
}

#[test]
fn alone_test() {
    let (busy, idle) = (helper(), helper());
    assert!(busy < idle * 4);
}

#[test]
fn floor_and_order_and_deadline() {
    let started = Instant::now();
    let mut sorted: Vec<u128> = (0..100).map(|_| helper().as_micros()).collect();
    sorted.sort();
    let (p99_us, max_us) = (sorted[98], sorted[99]);
    assert!(p99_us >= 10_000 && p99_us <= max_us);
    assert!(started.elapsed() < TIMEOUT * 3);
    let wait_p95 = helper();
    // not wall-clock: turns on the model's clock
    assert!(wait_p95 < P95_BUDGET_MS);
}
"""


def self_test() -> int:
    found = scan_text(SELF_TEST, "fixture.rs", lambda t: t.name != "alone_test")
    got = sorted(line.split("`")[1] for line in found)
    # `budget.p95` names a percentile but is the bound, so `metrics.p95 < budget.p95` is a percentile bound.
    want = ["percentile_against_a_budget_field", "percentile_in_default_run", "ratio_in_default_run"]
    print("\n".join(found))
    if got != want:
        print(f"self-test FAILED: flagged {got}, want {want}", file=sys.stderr)
        return 1
    print("self-test ok", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        return self_test()
    if not argv or argv[0].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    checkout = Path(argv[0]).resolve()
    if not checkout.is_dir():
        print(f"error: {argv[0]}: no such checkout", file=sys.stderr)
        return 2
    roots = [Path(a).resolve() for a in argv[1:]] or [checkout / "cmux-tui/crates"]
    cache: dict = {}
    found: list[str] = []
    for root in roots:
        if not root.exists():
            print(f"error: {root}: scan root does not exist", file=sys.stderr)
            return 2
        files = [root] if root.is_file() else sorted(p for p in root.rglob("*.rs") if "target" not in p.relative_to(root).parts)
        if not files:
            print(f"error: {root}: scan root holds no .rs file", file=sys.stderr)
            return 2
        for path in files:
            try:
                text = path.read_text()
            except (OSError, UnicodeDecodeError):
                continue
            ident = test_ident(path, checkout, cache)
            if ident is None:
                continue
            try:
                profiles = nextest_for(path, checkout, cache)
            except (OSError, tomllib.TOMLDecodeError, FilterError) as e:
                print(f"error: nextest config above {path}: {e}", file=sys.stderr)
                return 2
            beside = (lambda t, p=profiles: runs_beside_others(p, t)) if profiles is not None else None
            rel = str(path.relative_to(checkout)) if path.is_relative_to(checkout) else str(path)
            found.extend(scan_text(text, rel, beside, ident))
    for line in found:
        print(line)
    if found:
        print(
            f"\n{len(found)} wall-clock ratio or percentile assert(s) in the default test run. Keep a "
            "deterministic ordering or liveness check there and move the timing to an #[ignore]d test for "
            "its own run (cmux#41391; docs/handbook/timing-on-a-busy-host.md, fix 7).",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
