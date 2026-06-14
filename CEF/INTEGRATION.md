# CEF integration notes

CEF is wired into `cmux.xcodeproj` as a local Swift package named
`CMUXCEF`. New browser panes can opt into it through the Debug menu browser
engine selector; WKWebView remains the default.

## Source checkout setup

Run the repo setup script from the root:

```bash
./scripts/setup.sh
```

That script:

1. Initializes submodules.
2. Builds GhosttyKit.
3. Runs `CEF/vendor/fetch_cef.sh` to provision the CEF SDK used by SwiftPM and
   the helper build.

The CEF SDK step downloads the pinned tarball from `vendor/cef.lock.json`,
verifies size and SHA-256, extracts it under `CEF/CEF/`, builds
`libcef_dll_wrapper.a`, and populates `CEF/Frameworks/`.

## Xcode build behavior

The `Embed CEF` build phase runs `CEF/Scripts/embed_cef_into_cmux.sh`.

The build phase does not download the SDK. If `CEF/Frameworks/` is missing, it
fails with an explicit setup message. This keeps large network downloads in
`./scripts/setup.sh` instead of hiding them inside a regular Xcode build.

By default the build phase embeds only the small helper apps. It removes any
bundled `Chromium Embedded Framework.framework` so the app can start without a
large local runtime. CI or release experiments can opt into bundling the
framework with:

```bash
CMUX_EMBED_CEF_FRAMEWORK=1 ./scripts/reload.sh --tag cef-bundled
```

## App runtime behavior

When CEF is selected from `Debug > Browser Engine` and no runtime is installed,
cmux asks the user for confirmation, downloads the pinned runtime, verifies the
size and SHA-256, installs it under Application Support, and starts CEF from that
installed framework plus the bundled helper apps. If install or startup fails, cmux leaves WKWebView
available.

CEF runtime startup and helper execution require macOS 15.0 or later. On older
macOS versions, the browser engine selector falls back to WKWebView.

The installed runtime is keyed by the app bundle ID, so tagged debug builds are
isolated from each other. A given app bundle ID reuses the runtime on subsequent
launches.

## Signing and entitlements

Debug builds use `Resources/cmux.debug.entitlements`. Helper apps get the JIT
and executable-memory entitlements needed by Chromium; development-only helper
entitlements such as `get-task-allow` are added only for Debug helper builds.

Release builds use `Resources/cmux.entitlements`. Do not add debug-only
entitlements to the release file.

## Verification

Use a tagged debug build:

```bash
./scripts/reload.sh --tag cef-dev
```

Then launch the printed `.app`, switch `Debug > Browser Engine > CEF`, and
confirm that the runtime progress window appears only on first use. Switching
back to WKWebView should not remove the installed runtime.
