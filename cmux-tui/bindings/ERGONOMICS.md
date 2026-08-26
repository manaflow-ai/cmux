# SDK ergonomics findings

The seven public SDKs expose handwritten resource handles over the reviewed
124-operation `cmux.protocol/2` catalog. The raw protocol inventory is a
separate compatibility surface with 101 commands and 46 events. Deterministic
generation is limited to those private protocol-12 models under each package's
explicit `raw` namespace. Consumers do not run a generator or install a
generator runtime.

## Simulated consumers

| Language | Consumer | Changes driven by the simulation | Remaining convenience work |
| --- | --- | --- | --- |
| Python | Development orchestrator and agent watchdog | Added strict resource events, correlated creation recovery, durable terminal exit, synchronous and `asyncio` per-call deadlines, and typed duplicate-name handling. | Synchronous event processing still needs an application-owned reader thread. A reusable workspace-lease policy would be a convenience helper. |
| Rust | Agent dashboard and Ratatui sidebar monitor | Added typed agent upserts, terminal-targeted notifications, exact creation and exit variants, structured sidebar recovery, and a crates.io-compatible optional Ratatui wrapper. | Neither simulation needed a lower-level escape. |
| TypeScript | Browser controller | Added typed browser attachments, bounded queues, `AbortSignal`, lossless unknown events, exact creation-path unions, and a strict `pending` or `exited` terminal-wait union. | Topology-aware browser controllers still join browser snapshots to the session snapshot. Web pairing remains transport setup. |
| Go | Terminal bot | Added typed opaque IDs, durable creation and exit recovery, context-preserving errors, terminal-targeted notifications, session-scoped agent reporting, and retryable workspace cleanup. | The client-wide transport timeout can still bound a longer `WaitExit` call. |
| Java | CI orchestrator | Added strict terminal lifecycle and exit results, bounded streams, correlated recovery, and terminal-targeted notifications. | Per-call request deadlines, workspace leases, and plain-text history projection remain helpers rather than protocol gaps. |
| C++20 | Terminal frontend | Added a move-only typed attachment, validated history and attach options, typed notification and agent operations, and per-call deadline and cancellation controls for `Workspace::run`. | A reusable render reducer, focused-terminal lookup, and stop-token-aware open streams would reduce frontend code. |
| Zig | Session supervisor | Added narrow resource facades, exact machine/session discovery, correlated recovery, bounded session streams, and durable terminal exit results. | A typed correlated-create recovery combinator would remove repeated state narrowing and retry policy. |

## Defects exposed by the simulations

The standalone consumers found defects that shape-only tests missed:

1. Ordinary TUI and private-protocol mutations changed live state without
   updating durable public projections. All mutation paths now use the same
   coordinator to commit the durable registry projection, mutation receipt,
   public snapshot, and one revisioned event batch.
2. Zig omitted the workspace creation correlation key and resolved a terminal
   through the wrong route. Both wire paths now use their typed session and
   workspace ancestry.
3. TypeScript represented creation results as one object with optional path
   members and did not narrow terminal waits by status. Creation paths are now
   a strict discriminated union, deterministic methods return their exact path
   variant, and `pending` cannot be mistaken for a completed terminal exit.
4. Java could decode a terminal-scoped notification but could not create one.
   `NotificationCreate` now accepts an optional typed terminal ID.
5. C++ accepted generic JSON for terminal history and attachment options.
   Typed options now validate limits, paired dimensions, styling, and
   read-only mode before any write. Notification creation, notification
   listing, and agent reporting are now typed session operations too.
6. Go required an `Agent` returned by `agent.list` before reporting the first
   state for a new terminal. `Session.ReportAgent` now follows the catalog's
   machine and session ancestry directly.
7. The Rust sidebar wrapper compiled only with cmux's private Crossterm fork.
   The published crate now builds against crates.io Crossterm 0.29.
8. A quiet sidebar exposed request deadlines leaking into acknowledged stream
   reads in Rust, C++, and Zig. Their blocking stream APIs now wait indefinitely
   after acknowledgement, while open, bounded-poll, control, and cancellation
   deadlines remain explicit. All seven SDKs have delayed-event regressions
   that wait beyond the open deadline before delivering the first item.
9. Terminal multiview added `tab_ids` within protocol 1, exposing a version-skew
   failure when a new SDK decoded an older server's `tab_id`-only snapshot. All
   seven high-level decoders now synthesize the legacy singleton or empty list
   only when `tab_ids` is absent, while rejecting explicit malformed arrays.
These fixes are structural. They remove duplicate state publication, invalid
wire states, and public JSON escape hatches instead of hiding them in example
code.

Agent state events, durable terminal completion, mutation idempotency and
replay, structured protocol errors, and resumable session cursors are
implemented public behavior. None remains protocol work.

## Conformance evidence

The 124 public operations are the API inventory. The public fake-server
matrix is test inventory: 20 cases in each language, 140 cases total. It checks
exact envelopes, decimal preservation, mutation replay, indeterminate effects,
revision conflicts, duplicate-name ambiguity, bounded stream overflow,
cancellation ordering, all creation-resolution states, strict terminal exit,
and secret redaction.

The exact-binary live matrix adds one isolated create, run, exit, restart, and
cleanup flow per language. TypeScript repeats it over authenticated WebSocket,
for eight live transport runs. The separate raw protocol-12 suite runs 266
compatibility checks over its 101 commands and 46 events.

Each package suite also opens a stream with a short request deadline, leaves it
idle past that deadline, then delivers and cancels normally. This separates
request-handshake timeouts from application-owned stream lifetimes across all
seven transports.

Package tests install and consume the built npm package, Python wheel, Java
jar, and CMake package. Rust, Go, and Zig consumers resolve the public package
as downstream projects. The boundary checker rejects raw imports, legacy
numeric identity, missing operation descriptors, and generic resource
requests from the high-level roots.

## Dependency policy

Python, TypeScript, Go, Java, C++, and Zig use only their standard library at
runtime. C++ applications inject non-Unix transports. Rust uses `base64`,
`getrandom`, `libc`, `serde`, and `serde_json`; the optional sidebar companion
adds Crossterm and Ratatui without affecting the base client. No SDK installs
a client framework, code-generator runtime, or other major dependency.

The only repeated cross-language friction is correlated-create recovery.
Every SDK can resolve the correlation key exactly, but applications still
hand-write bounded handling for `not_applied`, `pending`, and `indeterminate`.
A typed helper that combines one create attempt, resolution, bounded waiting,
and exact-path narrowing would remove that policy duplication. Reducers,
leases, timeout overrides, and focused-resource lookup remain optional
handwritten utilities. None is required to reach a catalog operation.
