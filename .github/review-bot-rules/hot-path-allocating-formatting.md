# Hot-Path Allocating Formatting

Apply this rule to production Swift in hot, concurrent, or per-element paths: git index/path/signature encoding, terminal input/rendering, sidebar/feed/list rows, snapshot builders, and any loop or concurrent map that runs per byte, per row, per keystroke, or per frame. This is the formatting-specific sibling of `algorithmic-complexity.md`.

The lesson is from cmux PR https://github.com/manaflow-ai/cmux/pull/5347: building byte-to-hex signatures with `String(format:)` in the concurrent git-index snapshot path allocated per call and was extremely slow, causing unbounded memory growth and crashes on users' machines. The fix used a fixed hex lookup table written into a preallocated buffer.

## Fail

- `String(format:)` with per-element format conversions on a hot or concurrent path (hex/byte/signature encoding, per-row or per-frame string building).
- Allocating a `NumberFormatter`, `DateFormatter`, `ISO8601DateFormatter`, `ByteCountFormatter`, or similar per call inside a loop, row body, or concurrent map instead of reusing a cached/shared formatter.
- Repeated per-element string interpolation or concatenation that builds large intermediate strings on a hot path where a preallocated buffer or a single reserved-capacity build would avoid the churn.

## Pass

- Cold paths: one-shot formatting at startup, in a settings screen, in error/log construction, or anywhere not run per byte/row/keystroke/frame.
- A formatter allocated once and reused (cached property, shared instance) rather than per call.
- Deterministic encoding via a fixed lookup table written into a preallocated buffer, or another bounded constant-factor build with reserved capacity.
- Tests, benchmarks, and existing formatting code the PR does not move into a hotter or concurrent path.

## Report

When this rule fails, name the exact file and line, identify the hot/concurrent path, and propose the bounded replacement (preallocated buffer with a fixed hex table, a reused formatter, or reserved-capacity building). If unbounded memory growth or a user-machine crash is plausible, call it out as P0 per the PR #5347 regression class.
