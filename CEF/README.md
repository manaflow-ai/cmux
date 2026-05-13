# CMUXCEF

`CEF/` contains cmux's Chromium Embedded Framework integration. The app code
imports only the Swift `CMUXCEF` facade; CEF's C++ API stays behind the ObjC++
bridge in `Sources/CMUXCEFBridge`.

## Runtime Model

cmux keeps the CEF SDK needed for source builds separate from the Chromium
runtime shipped to end users:

- Source builds use `CEF/vendor/fetch_cef.sh` to download the pinned SDK,
  verify it against `vendor/cef.lock.json`, build `libcef_dll_wrapper.a`,
  and populate `CEF/Frameworks/`.
- Installed apps do not bundle the large Chromium framework by default. When a
  user selects CEF from the Debug menu for the first time, cmux downloads the
  same pinned runtime, verifies the size and SHA1, and installs it in
  Application Support.
- Subsequent launches reuse the installed runtime for the same app bundle ID.

This keeps the repository and app bundle small while still making the CEF
runtime opt-in and repeatable.

## Local Build

From the repo root:

```bash
./scripts/setup.sh
./scripts/reload.sh --tag cef-dev
```

`setup.sh` initializes submodules, builds GhosttyKit, and provisions the CEF
SDK for local builds. The CEF tarball is cached under
`~/Library/Caches/cmux-cef-vendor/`, so repeated setup runs are fast.

To refresh only the CEF SDK:

```bash
cd CEF
vendor/fetch_cef.sh
```

`CEF/CEF/`, `CEF/Frameworks/`, `.build/`, and `Package.resolved` are generated
artifacts and must not be committed.

## Package Layout

```text
CEF/
├── Package.swift
├── Sources/
│   ├── CMUXCEF/                 Swift facade used by cmux.app
│   ├── CMUXCEFBridge/           ObjC++ bridge and public C bridge header
│   ├── CMUXCEFHelper/           Browser helper entrypoint
│   ├── CMUXCEFHelperRenderer/   Renderer helper entrypoint
│   └── CMUXCEFDemoApp/          Local demo executable
├── Tests/
└── vendor/
    ├── cef.lock.json            Authoritative pinned CEF version
    ├── cef.lock.schema.json
    └── fetch_cef.sh
```

## Rules

- Do not commit CEF binaries or extracted SDK artifacts.
- Treat `vendor/cef.lock.json` as the source of truth for the CEF version,
  tarball, SHA1, size, and extracted directory name.
- Keep direct CEF C++ usage inside `CMUXCEFBridge`; Swift code should use the
  `CMUXCEF` API.
- Helper apps are embedded into `cmux.app/Contents/Frameworks/` by
  `Scripts/embed_cef_into_cmux.sh`.
- Runtime download UI and verification live in the main app so end users do
  not need to run provisioning scripts.
