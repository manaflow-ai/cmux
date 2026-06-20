# WKWebView file:// Access Keys

A `WKWebView` that loads a code-split ES-module React/Solid surface over `file://` mounts to a silent blank panel unless its configuration enables two KVC SPI keys. Over `file://` the document origin is `null`, so WebKit rejects every cross-origin module fetch; `main.mjs` never runs and no in-page error hook can fire — the only symptom is a blank surface.

Report a failure when the diff:

- Introduces a new webview coordinator that calls `loadFileURL(...)` for a surface that dynamically `import()`s code-split chunks, without enabling BOTH `allowFileAccessFromFileURLs` (on `configuration.preferences`) and `allowUniversalAccessFromFileURLs` (on the `configuration`) — or without calling the shared file-URL-access helper that sets them.
- Removes or bypasses those SPI keys (or the shared helper call) from an existing `file://`-loaded React/Solid coordinator.

Allowed cases:

- A webview whose bundle is a single inlined file with no dynamic `import()` (e.g. the current Solid renderer), with a comment stating the keys are not needed.
- A webview that loads remote `http(s)://` content — the keys are a `file://`-origin (`null`) workaround only.

cmux-specific emphasis:

- The reference is `AgentSessionWebRendererCoordinator`'s shared `allowFileURLAccess(_:)` helper; `KanbanWebRendererCoordinator` reuses it. Any new `file://`-loaded React surface must too.
- This is not caught by a build or a unit test — only at runtime, as a blank panel. Flag it at review time.

When reporting, name the coordinator and the missing SPI keys.
