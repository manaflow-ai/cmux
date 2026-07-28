# C++ SDK friction

## Public API used

Production code uses `cmux::Client`, generated request/result models, generated
event variants, `cmux::Result`, and `ClientOptions`. It does not construct raw
JSON or call raw command names.

Tests implement the public `cmux::Transport` interface, inject public
`TransportFactory` callbacks, and use public `cmux::Json` helpers to act as a
deterministic fake server. Raw JSON access is confined to verifying request
envelopes in those fake-server tests.

## Prioritized improvements

1. P0: Return an attachment handle with its server client ID. `attach_render`
   opens a separate connection but returns only `RenderStream`. To call
   `set_client_sizing` for that viewer, this example must call `list_clients`
   before and after attach, diff client IDs, then match surface and grid. Two
   concurrent attachments can make that inference ambiguous.

2. P0: Route sizing operations through the attachment connection.
   `release_surface_size` on `Client` affects the control connection, while the
   size claim belongs to the hidden render-stream connection. The example can
   release the claim only by closing the stream, so it cannot keep a warm
   attachment while hiding its viewport. An `Attachment` object should expose
   resize, release, close, surface ID, and client ID on one connection.

3. P1: Encode render-stream ordering in its type. `RenderStream` is an alias for
   `Stream<Event>`, so consumers must reject deltas before the first
   `render-state`, filter unrelated events, detect overflow, and interpret
   detach themselves. A `RenderAttachment::initial_state()` plus a
   `RenderUpdate` union would make the snapshot boundary explicit.

4. P1: Add topology selectors. Selecting the active PTY requires nested
   workspace, screen, `Pane::Variant`, active-tab index, dead flag, and tab-kind
   checks. Helpers such as `Tree::active_terminal()` and
   `Tree::find_surface(Id)` would remove repeated policy code.

5. P1: Provide a tested screen reducer. Every renderer must implement the same
   full-frame replacement, indexed-row patching, resize invalidation,
   default-color update, cursor update, and scroll metadata rules. A small
   optional `RenderModel` utility would preserve protocol semantics without
   imposing a UI toolkit.

6. P2: Add cancellation and reconnect policy hooks. `Stream::next()` has only a
   timeout, so graceful signal handling requires polling. A stop token and a
   reconnect helper that guarantees cache invalidation until a fresh snapshot
   would reduce application lifecycle code.

7. P2: Add composable `Result` operations. Checked access is safe, but every
   typed call needs manual success tests and error moves. `and_then`,
   `transform`, and `value_or` would make multi-command setup easier to read.

8. P2: Add ID parsing and formatting helpers. CLI consumers currently parse an
   integer themselves and cannot accept the short surface IDs shown by cmux.
