# TypeScript SDK consumer friction

No raw or private API was used. The example imports only `cmux/browser` and
calls named public methods. The fake transports implement the public
`Transport` and `WebSocketLike` interfaces.

## Prioritized SDK improvements

1. Add `attachBrowserSurface(surface)` returning
   `CmuxStream<BrowserAttachEvent>`. `attachSurface()` currently advertises a
   byte/render union even though default byte mode becomes a third browser
   stream at runtime. The forward-compatible `UnknownEvent` also has
   `event: string`, so an `event === "frame"` check does not narrow away the
   unknown shape. This example had to write runtime guards.
2. Separate command-response timeouts from event-idle behavior. Async stream
   iteration currently applies the client's command timeout to every `next()`.
   A healthy, quiet browser therefore raises `CmuxTimeoutError`. This example
   manually calls `next()` and treats timeouts as idle ticks.
3. Add `AbortSignal` support to attach and subscribe streams. Closing a stream
   works after attachment, but an abort cannot cancel an attachment request
   that is still waiting for its acknowledgement.
4. Specify the browser frame encoding and expose a decode helper or MIME-tagged
   frame type. `BrowserFrame.data` says only `Base64`; consumers cannot select
   an image decoder from the type or protocol documentation.
5. Add `listBrowserTabs()` or typed tree iterators. Discovery currently requires
   four nested loops, a live-pane structural guard, a `kind` filter, and a
   manual active-tab comparison.
6. Add DOM input adapters or documented constants for `browser-key` and
   `browser-mouse`. Callers must supply CDP `key`, `code`,
   `windows_virtual_key_code`, numeric modifier bits, button strings, and click
   counts without an SDK mapping from `KeyboardEvent` or `MouseEvent`.
7. Offer a reconnecting WebSocket client factory that retains pairing
   credentials and creates dedicated stream transports. `CmuxClient` and
   `WebSocketTransport` are composable, but consumers must coordinate their
   lifecycles and credential state.
8. Normalize browser tab nullability. `browser_source` is required and nullable,
   while `browser_status`, `browser_error`, and `browser_frames_stalled` are
   optional and nullable. The initial state frame is also optional and nullable.
   The example collapses each absent-or-null tab field to one `null` state.
9. Add a single-surface lookup or resync helper. Recovering one attachment from
   overflow currently fetches and walks the complete workspace tree.

## Useful existing behavior

All browser control commands have named typed methods. IDs and frame sequences
remain exact `bigint` values through an installed npm package. Browser-safe
exports avoid Node modules, transports are dependency-injectable, stream
buffers are bounded, and initial frames are represented in `browser-state`.
