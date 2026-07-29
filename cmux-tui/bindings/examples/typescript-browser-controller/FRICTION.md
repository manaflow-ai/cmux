# TypeScript SDK consumer friction

## Findings fixed during the simulation

1. `MutationOptions.correlationKey` covers all eight creation operations, and
   `session.creation.resolve` returns a typed recovery union with the exact
   created path.
2. `Browser.attach` has typed MIME-tagged frames, a 256-message and 16 MiB
   queue bound, explicit `cancel`, and `AbortSignal` cancellation.
3. Browser key modifiers are a closed union. Invalid modifier strings now fail
   during TypeScript compilation.

## Remaining SDK friction

1. `Pane.createBrowserTab` returns a generic `CreatedPath` whose browser,
   terminal, screen, pane, and tab fields are optional. This operation can
   only create a browser path, so the consumer still needs a runtime kind and
   presence check that should be encoded in its return type.
2. `Session.listBrowsers` does not include workspace, screen, or pane ancestry.
   Controllers that show topology must join a full session snapshot.
3. WebSocket authentication accepts an existing token but does not expose the
   pairing challenge and issued credential flow.

## Application concerns

Reconnect limits, resync delay, correlation keys, DOM-event coordinate
mapping, and whether a completed attachment should reopen are application
policy.

The source imports only `cmux/browser` and uses no low-level or private API.
