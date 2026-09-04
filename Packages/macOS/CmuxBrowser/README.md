# CmuxBrowser

WebKit remains the default. `cmux browser open --engine chromium URL` selects
Chromium for a new pane. Set `browser.defaultEngine` in cmux.json to change the
default for future panes. Existing session snapshots retain their engine.

```json
{
  "browser": {
    "defaultEngine": "chromium",
    "remoteDebuggingPort": 0,
    "extensionDirectories": ["/absolute/path/to/unpacked-mv3-extension"]
  }
}
```

With no extensions, the runtime is Chrome for Testing's pinned
`chrome-headless-shell` 152.0.7977.42. Extension-enabled panes use the matching
full Chrome for Testing in headless mode because headless-shell omits the MV3
extension system. Both architectures and both runtime archives have pinned
SHA-256 hashes in `ChromiumRuntimeManifest`. First use downloads, verifies and
atomically installs the complete runtime. No browser code runs inside cmux.

Unpacked MV3 directories are an explicit user trust decision. cmux validates
paths, manifests and scripts, rejects symlinks, and limits each extension to
256 MB and 20,000 files (32 extensions per configuration). Chrome performs the
final manifest validation through `Extensions.loadUnpacked`. Invalid or
unavailable extensions produce a localized diagnostic with the directory and
remedy while the pane falls back to WebKit. Reopen panes after configuration
changes.

Extension code is copied into immutable snapshots under the cmux profile ID.
A stable public key preserves the extension ID across snapshot updates; a
manifest's explicit key is retained. Browser and extension state live in the
pane's persisted storage ID beneath the logical profile, avoiding Chrome's
exclusive profile-directory lock between simultaneously open panes. Restarting
a pane preserves its state; a different pane has a separate cookie and
extension-storage jar. Old code snapshots remain available to running panes.

Private CDP uses inherited descriptors by default. Setting a nonzero
`browser.remoteDebuggingPort` opts into an IPv4 loopback listener; if occupied,
cmux selects another loopback port and reports the actual `cdp_endpoint` in
browser JSON. Commands and events use the browser connection with an explicit
page target session. Loopback connections bypass configured network proxies.

The AppKit host presents decoded screencast frames and forwards input through
CDP. Frame retention keeps only the newest frame, decoding uses a dedicated
actor, pointer moves and viewport updates coalesce, and command/input queues
are bounded. DispatchIO owns cancellable pipe readiness. Stop/replacement
cancels outstanding work and waits for process exit before reusing storage;
a two-second shutdown deadline terminates a wedged child.

Remote-proxy sessions, explicitly ephemeral stores and active URL-allowlist
policies retain WebKit. Streamed Chromium content does not expose WebKit's
native accessibility tree, inspector, design-mode or native download UI.
WebKit fallback uses its existing navigation/delegate stack and reports its
actual engine.

## Verification

The package is independently testable with injected temporary storage,
URLSessions and startup deadlines:

```sh
swift test --package-path Packages/macOS/CmuxBrowser --disable-xctest
```

On a leased Mac, enable the real-runtime suite (it downloads pinned artifacts,
starts a loopback HTTP fixture and launches isolated renderer processes):

```sh
CMUX_TEST_CHROMIUM_RUNTIME=1 swift test \
  --package-path Packages/macOS/CmuxBrowser \
  --filter ChromiumRuntimeIntegrationTests
```

This covers private and loopback CDP, MV3 content scripts and service workers,
extension storage across restart, frames, input including Backspace, navigation,
evaluation, screenshots, concurrent restart and process cleanup. App integration
coverage is in `cmuxTests/ChromiumBrowserPanelTests.swift`; run it on the fleet.
