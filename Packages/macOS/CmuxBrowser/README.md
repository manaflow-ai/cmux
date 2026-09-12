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

Chromium panes use the pinned in-process CEF runtime, which renders through a native
CEF child window adopted into the cmux pane. The CEF framework and helper bundles
are downloaded once by `scripts/ensure-cef.sh`, verified by SHA-256, and embedded
by `scripts/embed-cef.sh`; no screenshot transport is used. CDP remains an
in-process DevTools control plane for automation and debugging.

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

The AppKit host adopts the CEF browser window over the pane rect. Native Chromium
handles painting, scrolling, focus, IME, and input; cmux owns visibility, geometry,
profile lifecycle, and renderer recovery. Stop/replacement waits for CEF's close
callback before reusing profile data, and the external message pump is bounded to
the AppKit run loop.

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

CEF package tests run without launching Chromium:

```sh
swift test --package-path Packages/macOS/CmuxCEF
```

For native dogfood, build with CEF embedding enabled and open a pane with
`--engine chromium`; the tagged app's CEF helper processes and DevTools automation
are then exercised in the real UI.

This covers private and loopback CDP, MV3 content scripts and service workers,
extension storage across restart, frames, input including Backspace, navigation,
evaluation, screenshots, concurrent restart and process cleanup. App integration
coverage is in `cmuxTests/ChromiumBrowserPanelTests.swift`; run it on the fleet.
