# SDK ergonomics findings

The seven public SDKs expose handwritten resource handles over the reviewed
111-operation `cmux.protocol/1` catalog. Deterministic generation is limited to
the private protocol-10 models under each package's explicit `raw` namespace.
Consumers do not run a generator or install a generator runtime.

## Simulated consumers

| Language | Consumer | Changes driven by the simulation | Remaining convenience work |
| --- | --- | --- | --- |
| Python | Development orchestrator and agent watchdog | Added strict resource events, correlated creation recovery, durable terminal exit, synchronous and `asyncio` per-call deadlines, and typed duplicate-name handling. | A renewable workspace lease needs protocol support. Synchronous event processing still needs a reader thread. |
| Rust | Agent dashboard and Ratatui sidebar monitor | Added typed agent upserts, terminal-targeted notifications, exact creation and exit variants, structured sidebar recovery, and a crates.io-compatible optional Ratatui wrapper. | Neither simulation needed a lower-level escape. |
| TypeScript | Browser controller | Added typed browser attachments, bounded queues, `AbortSignal`, lossless unknown events, and exact `CreatedTerminalPath` and `CreatedBrowserPath` results. | Topology-aware browser controllers still join browser snapshots to the session snapshot. Web pairing remains transport setup. |
| Go | Terminal bot | Added typed opaque IDs, durable creation and exit recovery, context-preserving errors, terminal-targeted notifications, and retryable workspace cleanup. | The client-wide transport timeout can still bound a longer `WaitExit` call. |
| Java | CI orchestrator | Added strict terminal lifecycle and exit results, bounded streams, correlated recovery, and terminal-targeted notifications. | Per-call request deadlines, workspace leases, and plain-text history projection remain helpers rather than protocol gaps. |
| C++20 | Terminal frontend | Added a move-only typed attachment, validated history and attach options, and per-call deadline and cancellation controls for `Workspace::run`. | A reusable render reducer, focused-terminal lookup, and stop-token-aware open streams would reduce frontend code. |
| Zig | Session supervisor | Added narrow resource facades, exact machine/session discovery, correlated recovery, bounded session streams, and durable terminal exit results. | A typed correlated-create recovery combinator would remove repeated state narrowing and retry policy. |

## Defects exposed by the simulations

The standalone consumers found defects that shape-only tests missed:

1. Ordinary TUI and private-protocol mutations changed live state without
   updating the public snapshot and event journal. All mutation paths now use
   the same durable coordinator and publish one revision batch.
2. Zig omitted the workspace creation correlation key and resolved a terminal
   through the wrong route. Both wire paths now use their typed session and
   workspace ancestry.
3. TypeScript represented creation results as one object with optional path
   members. It now uses a strict discriminated union, while deterministic
   methods return their exact path variant.
4. Java could decode a terminal-scoped notification but could not create one.
   `NotificationCreate` now accepts an optional typed terminal ID.
5. C++ accepted generic JSON for terminal history and attachment options.
   Typed options now validate limits, paired dimensions, styling, and
   read-only mode before any write.
6. The Rust sidebar wrapper compiled only with cmux's private Crossterm fork.
   The published crate now builds against crates.io Crossterm 0.29.

These fixes are structural. They remove duplicate state publication, invalid
wire states, and public JSON escape hatches instead of hiding them in example
code.

## Conformance evidence

The public fake-server matrix runs 20 cases in each language, 140 total. It
checks exact envelopes, decimal preservation, mutation replay, indeterminate
effects, revision conflicts, duplicate-name ambiguity, bounded stream
overflow, cancellation ordering, all creation-resolution states, strict
terminal exit, and secret redaction.

The exact-binary live matrix adds one isolated create, run, exit, restart, and
cleanup flow per language. TypeScript repeats it over authenticated WebSocket,
for eight live transport runs. The raw protocol-10 suite remains separate and
runs 266 compatibility checks over 87 commands and 44 events.

Package tests install and consume the built npm package, Python wheel, Java
jar, and CMake package. Rust, Go, and Zig consumers resolve the public package
as downstream projects. The boundary checker rejects raw imports, legacy
numeric identity, missing operation descriptors, and generic resource
requests from the high-level roots.

## Dependency policy

Python, TypeScript, Go, Java, C++, and Zig use only their standard library at
runtime. C++ applications inject non-Unix transports. Rust uses `base64`,
`getrandom`, `libc`, `serde`, and `serde_json`; the optional sidebar companion
adds Crossterm and Ratatui without affecting the base client.

Future reducers, leases, and recovery combinators belong in handwritten
language-specific utilities. They are not required to reach any catalog
operation and must not add a client framework dependency.
