# TypeScript SDK consumer friction

## Findings fixed during the simulation

1. `MutationOptions.correlationKey` covers all eight creation operations, and
   `session.creation.resolve` returns a typed recovery union with the exact
   created path.
2. `Browser.attach` has typed MIME-tagged frames, a 256-message and 16 MiB
   queue bound, explicit `cancel`, and `AbortSignal` cancellation.
3. Browser key modifiers are a closed union. Invalid modifier strings now fail
   during TypeScript compilation.
4. Creation paths are a strict discriminated union. Fixed operations such as
   `Pane.createBrowserTab` return their exact path variant, so browser, tab,
   pane, and screen handles are required after successful decoding.
5. Browser frames expose a nullable pointer-authority token. Mouse and wheel
   options require the exact non-null token and serialize it as
   `pointer_frame_seq`, preventing stale rendered pixels from authorizing
   input.

## Remaining SDK friction

1. `Session.listBrowsers` does not include workspace, screen, or pane ancestry.
   Controllers that show topology must join a full session snapshot.
2. WebSocket authentication accepts an existing token but does not expose the
   pairing challenge and issued credential flow.

## Application concerns

Reconnect limits, resync delay, correlation keys, DOM-event coordinate
mapping, and whether a completed attachment should reopen are application
policy.

The source imports only `cmux-sdk/browser` and uses no low-level or private API.
