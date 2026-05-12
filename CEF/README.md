# CMUXCEF — cmux-owned CEF facade

Swift package that gives cmux a clean, narrow interface to the Chromium
Embedded Framework. cmux app code only ever imports `CMUXCEF`; CEF's C++
API is sealed behind ObjC++ in `CMUXCEFBridge` and never leaks into
Swift.

Located at `Prototypes/cef-webview/cmux-cef/` while it incubates. When it
graduates to cmux proper, the entire directory moves to `CEF/` (or
`Sources/CEF/`) at the cmux repo root with no other changes.

## Layout

```
cmux-cef/
├── Package.swift                    SwiftPM manifest (swift-tools-version 6.2)
├── CEFArtifacts                     → ../upstream/CEFWebView/Frameworks  (symlink)
├── Sources/
│   ├── CMUXCEF/                     Public Swift facade
│   │   ├── CEFEngine.swift          Process-wide CEF lifecycle
│   │   ├── CEFEngineConfig.swift    Immutable startup config
│   │   ├── CEFProfile.swift         Per-profile (CefRequestContext) wrappers
│   │   └── CEFBrowser.swift         One per browser pane
│   ├── CMUXCEFBridge/               ObjC++; sole owner of CEF C++ interop
│   │   ├── include/CMUXCEFBridge.h
│   │   └── CMUXCEFBridge.mm
│   ├── CMUXCEFHelper/main.mm        Helper-process entrypoint (GPU, utility, ...)
│   └── CMUXCEFHelperRenderer/main.mm Helper-process entrypoint (renderer)
└── Tests/
    └── CMUXCEFTests/                Behavioural Swift-level tests
```

## Build

The CEF binary distribution must be provisioned by `../vendor/fetch_cef.sh`
before this package can build. The vendor script writes the framework +
headers + wrapper static into
`Prototypes/cef-webview/upstream/CEFWebView/Frameworks/`, and the
`CEFArtifacts` symlink inside this package points there.

```bash
# One-time, after a fresh checkout or a CEF version bump:
../vendor/fetch_cef.sh

# Build the package
swift build

# Run the (currently small) unit-test target
swift test
```

`swift test` exercises the Swift API surface that is well-defined before
CEF has been initialized. Tests that need a live CEF runtime are
**integration** tests; they live behind a separate target that boots
`CEFEngine` in `setUp`. See `Tests/CMUXCEFTests/CEFEngineTests.swift`.

## Public Swift API (stable)

```swift
import CMUXCEF

// 1. main() — route subprocess invocations before AppKit boots.
let code = CEFEngine.executeSubprocessIfNeeded()
if code >= 0 { exit(code) }

// 2. After applicationDidFinishLaunching:
try CEFEngine.shared.start(config: CEFEngineConfig(
    rootCachePath: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/cmux/CEFRoot"),
    extensionDirectories: cmux.curatedExtensionURLs,
    userAgentProduct: "cmux/\(Bundle.main.shortVersion)"
))

// 3. Per pane:
let profile = CEFProfileRegistry.shared.profile(named: "work")
let browser = try CEFEngine.shared.makeBrowser(
    profile: profile,
    initialURL: URL(string: "https://example.com")!
)
window.addChildWindow(browser.hostingWindow, ordered: .above)
// ... track placeholder frame, call browser.hostingWindow.setFrame(...) ...

// 4. applicationWillTerminate:
CEFEngine.shared.shutdown()
```

## Build hygiene rules (enforced by review, not yet by lint)

- `import CEFC++` / direct `cef_*` symbol usage in Swift is forbidden.
  All such code lives inside `CMUXCEFBridge`.
- Public Swift types are `Sendable` where the bridge guarantees thread-
  safety, otherwise `@MainActor`. There are no `nonisolated(unsafe)`
  globals other than the os_log handle inside the bridge.
- Helper executables (`CMUXCEFHelper`, `CMUXCEFHelperRenderer`) must
  contain only the `CefExecuteProcess` glue. They must never depend on
  cmux app modules.
- The bridge's `.mm` files are compiled `-std=c++20`. No exceptions.
- Anything tagged `CMUX_TODO` is a known gap tracked in `../DESIGN.md`.

## Skeleton scope vs. future work

What is **complete** in this package today:

- Public Swift API shape (`CEFEngine` / `CEFEngineConfig` / `CEFProfile`
  / `CEFBrowser` / `CEFBrowserDelegate`)
- ObjC++ bridge classes, header, ARC ownership rules
- Real `CefInitialize` / `CefShutdown` plumbing
- Real `CefExecuteProcess` subprocess routing in `+executeSubprocessIfNeededWithArgc:`
- Real `CefApp` subclass that forwards `--load-extension` and friends
- Real `CefRequestContext::CreateContext` from the profile registry
- Build wiring (cxxSettings, linker settings, framework + library
  embedding via `CEFArtifacts` symlink)
- Test target boots without CEF and passes 2/2 unit assertions

What is **stubbed** (marked `CMUX_TODO`) and lands in subsequent PRs:

- `createBrowserInProfile:initialURL:` actually creating a CEF browser
  via `CefBrowserView::CreateBrowserView` + `CefWindow::CreateTopLevelWindow`
- `CefClient` subclass plumbing `OnTitleChange` / `OnAddressChange` /
  `OnLoadingStateChange` / `OnLoadError` into
  `CMUXCEFBrowserBridgeDelegate`
- DevTools window
- Profile cache GC after the last referencing browser closes
