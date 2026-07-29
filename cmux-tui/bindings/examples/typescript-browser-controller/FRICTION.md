# TypeScript SDK consumer friction

1. Reconnect remains application-owned. The controller recreates `Client`,
   reselects the session, and reopens the browser attachment after resync.
2. `Session.listBrowsers()` returns browser handles with cached snapshots,
   which is sufficient for browser control. A topology-aware
   `listBrowserTabs()` helper would be needed when callers also want workspace,
   screen, and pane names.
3. `Browser.attach()` now has typed, MIME-tagged frames and `AbortSignal`
   cancellation. A completed stream does not explain whether the browser was
   detached, so the controller confirms presence with `browser.list`.
4. WebSocket authentication accepts an existing token, but the public
   transport exposes no pairing-challenge or credential-issued callbacks.
   Applications that start without a token need an external pairing flow.
5. DOM event adapters are still application code. Browser key, mouse, and
   wheel methods are typed, but consumers must map browser-native events to
   cmux coordinates and modifier names.

The source imports only `cmux/browser`. It uses no raw client, private module,
generic protocol escape hatch, or forward-compatible option map.
