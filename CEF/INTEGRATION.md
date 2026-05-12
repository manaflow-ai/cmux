# Wiring CMUXCEF into the cmux Xcode project

This is the manual checklist a human (or Xcode-aware agent) needs to run
once to make cmux build with the bundled CEF browser engine. After this
is done, `import CMUXCEF` works from any Swift file under `Sources/`,
and the CEF helper apps + framework get embedded into the cmux.app
bundle at build time.

The CMUXCEF Swift package itself (this directory) is already self-
contained. `swift build` succeeds from `CEF/` without touching the cmux
Xcode project.

## 1. Provision CEF binaries (one-off after a fresh checkout)

```bash
cd CEF
vendor/fetch_cef.sh
```

This downloads `cef_binary_146.0.10+g8219561+chromium-146.0.7680.179_macosarm64.tar.bz2`
(~270 MiB), verifies its SHA1 against `cef.lock.json`, extracts under
`CEF/CEF/`, builds the C++ wrapper, and lays out
`CEF/Frameworks/Chromium Embedded Framework.framework` + helpers.

The downloads are cached at `~/Library/Caches/cmux-cef-vendor/` so
subsequent runs are fast / offline-safe.

## 2. Add CMUXCEF as a local Swift Package dependency

In `GhosttyTabs.xcodeproj` → Project → Package Dependencies:

- Click **+** → **Add Local…**
- Navigate to `cmux/cef` and add the package.
- Add the **CMUXCEF** library to the `cmux` target's
  "Frameworks, Libraries, and Embedded Content".

`CMUXCEFHelper` and `CMUXCEFHelperRenderer` are exposed as executable
products of the same package — they will be needed by Step 4.

## 3. "Fetch CEF" build phase

On the `cmux` target → Build Phases, add a new **Run Script Phase**
above the "Copy Bundle Resources" phase:

```bash
"${SRCROOT}/CEF/vendor/fetch_cef.sh"
```

Input files: `$(SRCROOT)/CEF/vendor/cef.lock.json`
Output files: `$(SRCROOT)/CEF/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework`

This makes Xcode rerun the fetch only when the lockfile changes.

## 4. Embed the CEF framework + helper apps

Add another Run Script Phase **after** "Compile Sources" and **before**
"Embed Frameworks":

```bash
set -euo pipefail
FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/../Frameworks"
mkdir -p "${FRAMEWORKS_DIR}"

# 1. Framework
rsync -a --delete \
  "${SRCROOT}/CEF/Frameworks/Chromium Embedded Framework.framework" \
  "${FRAMEWORKS_DIR}/"

# 2. Build SPM helper executables for the cmux configuration.
SWIFT_CFG=$(echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')
case "${SWIFT_CFG}" in
  debug|release) ;;
  *) SWIFT_CFG="debug" ;;
esac

(cd "${SRCROOT}/CEF" && xcrun swift build -c "${SWIFT_CFG}" \
  --product CMUXCEFHelper --product CMUXCEFHelperRenderer)

ARCH="$(uname -m)"
BUILD_BIN="${SRCROOT}/CEF/.build/${ARCH}-apple-macosx/${SWIFT_CFG}"

# 3. Wrap helpers into the .app bundles that CEF expects.
"${SRCROOT}/CEF/Scripts/embed_helpers_into_bundle.sh" \
  "${BUILD_BIN}/CMUXCEFHelper" \
  "${BUILD_BIN}/CMUXCEFHelperRenderer" \
  "${FRAMEWORKS_DIR}"
```

`Scripts/embed_helpers_into_bundle.sh` is a thin wrapper around the
prototype's `Sources/WebView/Scripts/embed_cef_helpers.sh` adapted to
this layout — I will land that script once the build phase is in place.

## 5. Entitlements

The browser-process target (cmux) and the helper apps all need V8 JIT
and unsigned executable memory. Add to **cmux.entitlements**:

```xml
<key>com.apple.security.cs.allow-jit</key>
<true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
```

For **debug builds only** (cmux.entitlements is shared) the CEF
framework is ad-hoc signed by `vendor/fetch_cef.sh`, so library
validation has to be relaxed:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

Production builds re-sign CEF with the cmux Developer ID; the
`disable-library-validation` entitlement is removed from the release
entitlements file.

Helper apps get their own entitlements plist with the same three
entries plus `get-task-allow` for dev builds. The embed script in
Step 4 writes that plist.

## 6. Verify

```bash
./scripts/reload.sh --tag cef-feature
```

Should build cleanly. Launch the resulting `cmux DEV cef-feature.app`
— it boots normally because the CEF code path is gated behind a
feature flag and the flag is off by default. The build success is the
acceptance criterion for this step.

## 7. Flip the flag and write `CEFBrowserPanel`

That's Step 3 of `Prototypes/cef-webview/notes/cmux-integration-plan.md`
and is done in a follow-up PR.

---

## Why this is split out

`project.pbxproj` is brittle; editing it via text manipulation breaks
the project file in subtle ways that only surface when Xcode tries to
parse it. The five edits above are simpler to do in Xcode's UI than to
script, so the integration is documented as a checklist rather than
applied automatically.

The CMUXCEF package itself is fully self-sufficient (it builds with
`swift build` from this directory). Everything else is "Xcode plumbing
for embedding it inside cmux."
