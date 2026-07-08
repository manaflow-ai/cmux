# CmuxChromium

Embeds the OWL Chromium runtime (built by [manaflow-ai/chromium](https://github.com/manaflow-ai/chromium)) as an experimental browser engine for cmux.

The runtime is a Content Shell build plus `libowl_fresh_mojo_runtime.dylib`. The dylib is `dlopen`ed at runtime — never linked — and launches one Content Shell process per session, controlled over Mojo IPC. Rendering is zero-copy: the shell's GPU compositor exports a `CAContext` and `ChromiumWebView` mounts a `CALayerHost` with that ID.

## Usage

```swift
let bundle = try ChromiumRuntimeLocator().locate()
let runtime = ChromiumRuntime(bundle: bundle)
try await runtime.start()                    // pins the runtime thread for process lifetime
let session = try await runtime.openSession(initialURL: "https://example.com")
let model = ChromiumBrowserModel()
let view = ChromiumWebView(session: session, model: model)  // consumes session.events
```

Install a runtime with `scripts/fetch-chromium-runtime.sh` (installs under `~/Library/Application Support/cmux/chromium-runtime/<commit>/`), or point `CMUX_CHROMIUM_RUNTIME_DIR` at an extracted archive.

## Threading

The runtime is thread-affine: `owl_fresh_mojo_global_init` installs Chromium's `SingleThreadTaskExecutor` on the calling thread, and every later call plus event delivery must happen there. `ChromiumRuntimeExecutor` owns that pinned thread and hands commands across; `ChromiumSession` exposes ordinary `async` methods and an `AsyncStream` of events on top.

## Testing

Pure logic takes its dependencies through `init`: `ChromiumRuntimeLocator` accepts a `FileManager`, an environment dictionary, and an install-root override, so tests run against temp directories:

```swift
let locator = ChromiumRuntimeLocator(environment: [:], installRoot: tempDir)
```

`ChromiumKeyTranslation`, `ChromiumRuntimeManifest`, and the C-event mapping are value-level and test directly. Nothing in the test suite requires an installed runtime.
