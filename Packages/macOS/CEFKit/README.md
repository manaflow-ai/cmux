# CEFKit

Pure-Swift bindings to the Chromium Embedded Framework (CEF) C API, giving
cmux a real Chrome engine: Chromium rendering in an NSView, the Chrome
extension system (uBlock, Dark Reader, MV2 and MV3 unpacked extensions), and
isolated Chrome profiles. No ObjC++, no C++ wrapper (`libcef_dll_wrapper`),
and no third-party binding layer — Swift talks to `include/capi` directly.

## Why custom bindings

Prior art (`cef-swift-mvp`, `references/CEFWebView`) routed Swift through an
ObjC++ shim plus a Rust crate or the C++ wrapper. Those layers hide the
reference-counting contract, pin us to another toolchain, and expose
app-specific APIs instead of a library. CEFKit is ~1,300 lines of Swift over
the C headers:

- **CCEF** — a Clang module over the CEF distribution's `include/capi`
  headers (an `include` symlink into the fetched distribution; no unsafe
  flags, so the package is consumable from the cmux Xcode project as a plain
  local package).
- **CEFHandler** — the one piece of machinery CEF bindings need: Swift
  objects exposed as CEF's ref-counted handler structs. Each handler is
  allocated as `[16-byte header | cef struct]`; the header carries an atomic
  refcount and an Unmanaged reference to the owning Swift object, and the
  four `cef_base_ref_counted_t` callbacks are fixed C functions that recover
  the header by pointer arithmetic. Works for every handler struct with no
  code generation.
- **CEFRuntime** — libcef entry points resolved with `dlsym` after
  `CEFLibraryLoader` dlopens the framework from the app bundle. Host apps
  need zero CEF linker flags.
- **CEFApp / CEFMessagePump** — Chrome-bootstrap initialization with
  `external_message_pump`: CEF work is driven by the host's main RunLoop
  (schedule-driven timers plus a 30 Hz backstop), so it coexists with an
  existing NSApplication event loop. Initialization is lazy; apps that never
  open a browser pay nothing.
- **CEFKitApplication** — the NSApplication subclass CEF requires
  (`CefAppProtocol` send-event tracking), declared in the shim header and
  implemented in Swift. Set it as `NSPrincipalClass`.
- **CEFBrowser / CEFClient** — browser creation in a parent NSView
  (Alloy-style under the Chrome bootstrap), navigation, and delegate
  callbacks (URL/title/loading state/close).
- **CEFProfile** — Chrome profiles as CEF request contexts with caches at
  `<root>/Profile-<name>`; cookies/storage verified isolated.
- **CEFDevTools / CEFDevToolsWindow** — DevTools docked in an app view or in
  an app-owned window, implemented the embedder way: a browser loading the
  DevTools frontend from the CDP endpoint (`remoteDebuggingPort`). CEF
  cannot parent its native DevTools to an NSView on macOS (issue #3294), and
  its Chrome-style DevTools window is unstable under window churn in CEF 146,
  so `CEFBrowser.showDevToolsWindow()` exists but is not the recommended
  path.

## Ownership rules that bit us (encoded in the bindings)

- Passing a ref-counted struct as a function argument transfers one
  reference. Kept pointers (a profile's request context) are add_ref'd
  before every pass; missing this frees the wrapper and later fatals with
  "UnwrapDerived called with unexpected class type".
- Request contexts initialize asynchronously, so browser creation is async
  (`cef_browser_host_create_browser`); the sync variant with a fresh profile
  is a fatal DCHECK.
- Closing a browser whose NSView is still in a live window over-releases the
  host NSWindow (objc_zombie "NSWindow received -retain" crash under resize
  churn). `CEFBrowser.close()` detaches the browser view first.
- A window hosting a browser must outlive the browser's asynchronous
  destruction; `CEFDevToolsWindow` waits for `browserDidClose` before
  releasing its NSWindow.

## Setup

```bash
Packages/macOS/CEFKit/scripts/fetch-cef.sh   # ~700 MB download, or point
# CEFKIT_CEF_SOURCE at an existing extracted distribution to symlink it.
```

The distribution lands in `third_party/cef/current` (gitignored). Without
it, the package does not build and cmux dev builds simply skip bundling CEF.

## Demo app

`Demo/` is a self-contained browser app (xcodegen) used for development and
stress testing:

```bash
Demo/scripts/build.sh          # build CEFDemo.app
Demo/scripts/run-stress.sh 90  # crash gauntlet; see below
bun Demo/scripts/verify.mjs    # functional proof over CDP
```

`verify.mjs` proves the three claims end to end: pages render per profile,
`document.cookie` written in one profile is invisible to the others, and the
bundled test extension's content script injected its marker. `run-stress.sh`
launches the app with continuous window-resize jiggle, profile switching,
and DevTools dock/undock cycling while `stress.mjs` hammers every page over
CDP with navigation, typing, clicks, scrolls, and drag events; it fails if
the process crashes or any page stops answering.

## cmux integration (dev builds)

- `scripts/copy-cef-runtime-dev.sh` (build phase "Copy CEF Runtime (dev
  only)") bundles the framework, helper apps, and test extension into Debug
  builds when the distribution is present; Release and CI builds are
  untouched.
- Debug menu → Debug Windows → "Chromium Browser (CEF)…", or command
  palette "Chromium Browser (CEF)" (`palette.openCefBrowser`).
- CEF initializes on first open (per-bundle-id cache under Application
  Support, stable per-bundle-id CDP port; override with
  `CMUX_CEF_DEBUG_PORT`).

## Pinned CEF

`cef_binary_146.0.5+g4db0d88+chromium-146.0.7680.65_macosarm64_beta`, API
version pinned via `cef_api_hash(CEF_API_VERSION_LAST)` at load. The beta
channel ships with DCHECKs enabled, which is deliberate for now: it turns
binding contract violations into deterministic crashes instead of silent
corruption. Switch to a stable-channel build before shipping to users.
