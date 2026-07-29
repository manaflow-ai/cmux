# C++ SDK friction

Production code uses `cmux::Client`, opaque resource IDs, resource handles,
typed creation paths, typed terminal results, typed attachment items, and
`cmux::Result`. It does not use numeric mux IDs, generated protocol-v10 models,
raw commands, or JSON documents.

Tests implement the public `cmux::Transport` interface and use public
`cmux::Json` only to simulate and inspect wire envelopes.

The strict resource API resolved the earlier attachment problems. A
`TerminalAttachmentStream` now owns the stream connection, exposes typed
snapshot, patch, scroll, and unknown variants, provides bounded `poll`, and
routes typed viewer resize, release, and cancellation through that connection.
Opaque ID parsers, selectors, typed screen/history results, durable terminal
lifecycle and exit outcomes, deterministic creation paths, and correlation
recovery also work directly.

Remaining friction:

1. `Workspace::run` does not accept `CallOptions`, so one launch cannot set a
   deadline or cancellation token independently of the client-wide timeout.
2. `Terminal::read_history` and `Terminal::attach` accept generic
   `Json::Object` options. This example can use their defaults, but non-default
   paging or attachment flags lose compile-time field checking.
3. Styled history has no standard plain-text projection. Text consumers must
   concatenate render runs and pages themselves.
4. The SDK validates render item shapes but does not provide a screen reducer.
   Each frontend still implements full-frame replacement, indexed patching,
   resize reset, cursor, color, and scroll state.
5. Selecting the focused terminal from `ResourceSnapshot` requires joining a
   focused `TabSnapshot.content_id` to `TerminalSnapshot`. A shared
   `focused_terminal()` policy helper would prevent each consumer from
   repeating this join.
6. `ResourceStream::poll` is bounded, and `cancel` is deterministic, but an
   already-open stream does not accept a stop token. Graceful shutdown requires
   timed polling followed by explicit cancellation.
7. `Session::resolve_creation` returns the correct closed `CreatedPath` union,
   but recovery of a known operation still requires a runtime variant check.

The example's recovery, lifecycle validation, attachment ownership, and opaque
ID routing are principled. The local screen reducer is necessary application
logic, but it is generic enough to belong in an optional SDK utility.
