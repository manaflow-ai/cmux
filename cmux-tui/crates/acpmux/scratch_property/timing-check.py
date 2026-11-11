#!/usr/bin/env python3
"""Find wall-clock ratio and percentile asserts in a cmux checkout's default Rust test run.

A local check, run by hand on a cmux checkout before pushing a timing test; no CI step runs it.
The class (docs/handbook/timing-on-a-busy-host.md, fix 7): a test in the default, non-ignored run
times work on the wall clock and asserts a ratio of two timings (`busy < idle * 4`) or an upper
percentile bound (`p95 < bound`). CI runs cmux-tui's tests under cargo-nextest, one process per test
and every test binary at once, so the load beside the test sets the number: cmux#41346 went red on
`busy < idle * 4` in acpmux's lib run, fixed in cmux#41391. Keep a deterministic ordering or liveness
check in the default run and move the ratio to an `#[ignore]`d test for its own run
(`--ignored --exact --test-threads=1`). A test in nextest's `timing-alone` group
(cmux-tui/.config/nextest.toml) runs alone already and is not reported.

Usage: python3 tools/rust-timing-ratio/check.py CMUX_CHECKOUT [PATH ...]
       python3 tools/rust-timing-ratio/check.py --self-test
PATH defaults to CMUX_CHECKOUT/cmux-tui/crates. Exit 1 when it finds one. A bound on a model's clock,
not the wall clock, carries a `// not wall-clock: <why>` comment on the line above its assert.
Heuristic, by names: it misses a percentile kept under another name (`g50`, a helper's median).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


TEST_ATTR = re.compile(r"#\[(?:tokio::)?test\b[^\]]*\]")
FN = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)")
WALL_CLOCK = re.compile(r"\bInstant::now\(\)|\.elapsed\(\)|\bSystemTime::now\(\)")
ASSERT = re.compile(r"\b(?:debug_)?assert!\s*\(")
CMP = re.compile(r"(?<![<>=!-])(<=|>=|<|>)(?![<>=])")
# Lowercase only, as TIMING_NAME: `P95_BUDGET_MS` is the bound, `p95` the measurement.
PERCENTILE = re.compile(r"(?<![A-Za-z0-9_])[a-z_][a-z0-9_]*(?:p50|p90|p95|p99|p999|median|percentile)[a-z0-9_]*\b|\b(?:p50|p90|p95|p99|p999|median)\b")
# A measured timing: a lowercase name (a constant is a configured bound, not a measurement).
TIMING_NAME = re.compile(
    r"\b[a-z_]\w*(?:elapsed|took|latency|wall|busy|idle|loaded|quiet|baseline|cold|warm|echo|round_trip|rtt|_us|_ms|_ns)\w*\b"
    r"|\b(?:elapsed|took|latency|wall|busy|idle|loaded|quiet|baseline|cold|warm|echo|rtt)\b"
)
FILTER_OPEN = re.compile(r"filter\s*=\s*'''")
TIMING_ALONE_GROUP = re.compile(r"\s*\ntest-group\s*=\s*'timing-alone'")
TEST_NAME = re.compile(r"test\(=(?:[\w:]*::)?(\w+)\)")
SCALED = re.compile(r"\*\s*\d+(?:\.\d+)?\b|\b\d+(?:\.\d+)?\s*\*|/\s*\d+(?:\.\d+)?\b")


def timing_alone_tests(checkout: Path) -> set[str]:
    try:
        text = (checkout / "cmux-tui/.config/nextest.toml").read_text()
    except OSError:
        return set()
    # One pass: find each opening, then its closing ''' with str.find, so a file of
    # unclosed openings costs linear time (a lazy (.*?) here was quadratic).
    names: set[str] = set()
    pos = 0
    while (opening := FILTER_OPEN.search(text, pos)) is not None:
        close = text.find("'''", opening.end())
        if close < 0:
            break
        if TIMING_ALONE_GROUP.match(text, close + 3):
            names.update(TEST_NAME.findall(text, opening.end(), close))
        pos = close + 3
    return names


def strip_line_comment(line: str) -> str:
    out, in_str, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_str = not in_str
        if not in_str and line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out)


def test_functions(lines: list[str]):
    """(name, attributes, first body line index, last body line index) of each test fn."""
    i = 0
    while i < len(lines):
        if not TEST_ATTR.search(lines[i]):
            i += 1
            continue
        attrs = [lines[i]]
        j = i + 1
        while j < len(lines) and not FN.match(lines[j]):
            attrs.append(lines[j])
            j += 1
            if j - i > 12:
                break
        m = FN.match(lines[j]) if j < len(lines) else None
        if not m:
            i = j
            continue
        depth, start, k = 0, j, j
        opened = False
        while k < len(lines):
            code = strip_line_comment(lines[k])
            depth += code.count("{") - code.count("}")
            opened = opened or "{" in code
            if opened and depth <= 0:
                break
            k += 1
        k = min(k, len(lines) - 1)
        yield m.group(1), "\n".join(attrs), start, k
        i = k + 1


def statement(lines: list[str], at: int, end: int) -> str:
    parts, depth = [], 0
    for k in range(at, end + 1):
        code = strip_line_comment(lines[k])
        parts.append(code.strip())
        depth += code.count("(") - code.count(")")
        if depth <= 0 and code.rstrip().endswith(";"):
            break
    return " ".join(parts)


def condition(stmt: str) -> str:
    """The first argument of assert!(...), the condition."""
    open_at = stmt.find("(", ASSERT.search(stmt).start())
    depth, out = 0, []
    for c in stmt[open_at + 1 :]:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            break
        out.append(c)
    return "".join(out)


# A side naming a budget is the bound, even when it names a percentile (`budget.p95`).
BOUND_WORD = re.compile(r"budget|bound|limit|deadline|timeout|allowed", re.I)


def measured(side: str) -> bool:
    return not BOUND_WORD.search(side) and bool(TIMING_NAME.search(side) or PERCENTILE.search(side))


def finding(cond: str) -> str | None:
    for side_pair in re.split(r"&&|\|\|", cond):
        m = CMP.search(side_pair)
        if not m:
            continue
        left, right = side_pair[: m.start()], side_pair[m.end() :]
        measured_left = measured(left)
        measured_right = measured(right)
        scaled = bool(SCALED.search(left) or SCALED.search(right))
        if measured_left and measured_right:
            if scaled:
                return "ratio of two timings"
            continue  # p99 <= max: one sample set's own order, which load does not change
        # Only an upper bound: load makes a timing longer, so a lower bound (a sleep's floor) holds.
        upper = m.group(1) in ("<", "<=")
        if (upper and PERCENTILE.search(left)) or (not upper and PERCENTILE.search(right)):
            return "percentile bound"
    return None


def scan(path: Path, alone: set[str], root: Path) -> list[str]:
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError):
        return []
    return scan_text(text, str(path.relative_to(root) if path.is_relative_to(root) else path), alone)


def scan_text(text: str, rel: str, alone: set[str]) -> list[str]:
    lines = text.splitlines()
    found = []
    # The clock read may sit in a helper the test calls (remote_table_bench's notices_round), so
    # the file, not the test body, has to read the wall clock.
    if not WALL_CLOCK.search("\n".join(strip_line_comment(line) for line in lines)):
        return found
    for name, attrs, start, end in test_functions(lines):
        if "#[ignore" in attrs or "start_paused" in attrs or name in alone:
            continue
        for k in range(start, end + 1):
            if not ASSERT.search(strip_line_comment(lines[k])):
                continue
            if k > 0 and "not wall-clock:" in lines[k - 1]:
                continue
            kind = finding(condition(statement(lines, k, end)))
            if kind:
                found.append(f"{rel}:{k + 1}: {kind} in default-run test `{name}`: {lines[k].strip()}")
    return found


SELF_TEST = """
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
    let metrics = measure();
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
    let (p99_us, max_us) = (1, 2);
    assert!(p99_us >= 10_000 && p99_us <= max_us);
    assert!(started.elapsed() < TIMEOUT * 3);
    // not wall-clock: turns on the model's clock
    assert!(wait_p95 < P95_BUDGET_MS);
}
"""


def self_test() -> int:
    found = scan_text(SELF_TEST, "fixture.rs", {"alone_test"})
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
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    checkout = Path(argv[0]).resolve()
    roots = [Path(a).resolve() for a in argv[1:]] or [checkout / "cmux-tui/crates"]
    alone = timing_alone_tests(checkout)
    found = []
    for root in roots:
        files = [root] if root.is_file() else sorted(p for p in root.rglob("*.rs") if "/target/" not in str(p))
        for path in files:
            found.extend(scan(path, alone, checkout))
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
