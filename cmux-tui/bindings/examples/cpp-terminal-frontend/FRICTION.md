# C++ SDK friction

Production code uses `cmux::Client`, opaque resource IDs, resource handles,
typed creation paths, typed terminal results, typed attachment items, and
`cmux::Result`. It does not use numeric mux IDs, generated protocol-v12 models,
raw commands, or JSON documents.

Tests implement the public `cmux::Transport` interface and use public
`cmux::Json` only to simulate and inspect wire envelopes.

The strict resource API resolved the earlier attachment problems. A
`TerminalAttachmentStream` now owns the stream connection, exposes typed
snapshot, patch, scroll, and unknown variants, provides bounded `poll`, and
routes typed viewer resize, release, and cancellation through that connection.
Opaque ID parsers, selectors, typed screen/history results, durable terminal
lifecycle and exit outcomes, deterministic creation paths, and correlation
recovery also work directly. `Workspace::run` accepts per-call deadlines and
cancellation. History paging and attachment sizing and read-only flags use
validated option types. Session notification creation, notification listing,
and initial agent reports also use typed options and results.

Remaining friction:

1. Styled history has no standard plain-text projection. Text consumers must
   concatenate render runs and pages themselves.
2. The SDK validates render item shapes but does not provide a screen reducer.
   Each frontend still implements full-frame replacement, indexed patching,
   resize reset, cursor, color, and scroll state.
3. Selecting the focused terminal from `ResourceSnapshot` requires joining a
   focused `TabSnapshot.content_id` to `TerminalSnapshot`. A shared
   `focused_terminal()` policy helper would prevent each consumer from
   repeating this join.
4. `ResourceStream::poll` is bounded, and `cancel` is deterministic, but an
   already-open stream does not accept a stop token. Graceful shutdown requires
   timed polling followed by explicit cancellation.
5. `Session::resolve_creation` returns the correct closed `CreatedPath` union,
   but recovery of a known operation still requires a runtime variant check.

The example's recovery, lifecycle validation, attachment ownership, and opaque
ID routing are principled. The local screen reducer is necessary application
logic, but it is generic enough to belong in an optional SDK utility.
