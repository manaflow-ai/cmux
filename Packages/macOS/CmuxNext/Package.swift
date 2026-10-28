// swift-tools-version: 6.2

import PackageDescription
#if os(Linux)
import Foundation
#endif

// Umbrella package for the cmux-next app (plans/cmux-next/shell.md).
// The Xcode target `cmux-next` compiles only App/main.swift and links the
// `CmuxNextApp` product; every other line of app code lives here, split into
// modules so later agents can work on them in parallel.
//
// Dependency direction (no cycles, no upward imports):
//   CmuxNextApp -> every feature module
//   CmuxNextBridge -> Daemon, Layout, Sidebar, Tabs (App-layer mapping, testable); Oracle (the layout facet)
//   CmuxNextBrowserCore -> Compat, Wakeups, CmuxSafeConcurrency (the browser's engine-neutral values and protocols; Browser re-exports it)
//   CmuxNextFavicons -> CmuxNextBrowser, CmuxNextTabs (public read-only favicon leaf)
//   CmuxNextTabs, Sidebar, Layout, Browser -> CmuxNextDesign; Tabs, Sidebar -> CmuxNextIcons; Palette -> Design, Actions
//   CmuxNextBrowser -> Input, InputCore (page link clicks, swipes and mouse side buttons hear the app's input tap)
//   Feature UI modules never import CmuxNextDaemon; the App maps daemon state into their view models.
//   CmuxNextTerminal -> CmuxNextTerminalGeometry, CmuxNextCopyMode (pure), CmuxGhosttyKit (binary)
//   CmuxNextCompat -> swift-atomics, CmuxSafeConcurrency, CmuxThreading, system frameworks (back-ports of newer system APIs for the
//     macOS 14 floor: Mutex, Atomic; any module may import it; plans/cmux-next/macos-floor.md)
//   CmuxNextWakeups -> Compat, CmuxSafeConcurrency, Signposts, Trace, Metrics, system frameworks (the only sanctioned wakeup
//     primitives: FrameScheduler, DemandTimer, Backoff, WakeupLedger, the one main-thread scheduler's
//     per-frame budget MainFrameBudget, and TracedTask; plans/cmux-next/idle-wakeups.md,
//     main-thread-budget.md). Every target that calls Task.detached depends on it, except Compat.
//   CmuxNextDesign -> CmuxTheme, CCmuxAppFFI (cmux-motion curves and color mix), Icons (OverflowButton's glyph),
//     Wakeups, Trace, Metrics, Signposts; CmuxNextActions -> Signposts, Wakeups, Trace, Metrics;
//     CmuxNextDaemon -> Compat, Wakeups, Trace, Metrics, Signposts (the p09-observability trace points and histograms),
//       IPC (the generated `cmux.protocol/2` requests ResourceOperationClient sends, p05-ipc-045),
//       CmuxSafeConcurrency (OnceContinuation, p10-stability-087)
//   CmuxNextSignposts -> Compat, Trace, Metrics, SignpostsC, system frameworks (always-on os_signpost intervals, the one
//     name catalog, CommitBoundary, the opt-in MetricKit mirror for hang reports, the typed ring trace points; Metrics for
//     the key.frame and input.frame histograms, p09-observability tasks 054 and 111)
//   CmuxNextSignpostsC -> libSystem only (C: os_signpost macros for the key and stall signposts, no heap allocation;
//     p09-observability task 007)
//   CmuxNextLaunch -> Compat, Signposts, Trace, Wakeups, Design, InputCore, ProfileRuntimeC (launch-only types: the launch
//     image hold, and the startup trace, temperature and saved window picture to come; the App only wires them;
//     plans/cmux-next/chrome-parity/p08-startup.md, task 073; Trace: LaunchMarks moves each mark's date onto the
//     trace clock through the launch's one LaunchClock pairing)
//   CmuxNextProfileRuntimeC -> nothing (C header: the compiler-rt profile runtime's write, reset and file name,
//     which only the profile build calls; p08-startup task 103)
//   CmuxNextTrace -> Compat, swift-atomics (the process's TraceRuntime: category flags, Release trace rings, crash-key page,
//     HangWatch slots and scopes; plans/cmux-next/chrome-parity/p09-observability.md)
//   CmuxNextMetrics -> Compat, Trace (the field-histogram catalog HistogramID and Metrics.record)
//   CmuxNextDesignTokens -> Compat, Wakeups, CmuxTheme, CCmuxAppFFI (Design's values without views: tunables,
//     motion tokens, theme specs, settings enums; CmuxNextDesign re-exports it)
//   CmuxNextFeatures -> Compat, Wakeups, swift-atomics (base::FeatureList: the feature registry and the immutable
//     resolved snapshot the App builds once, and the signed remote document's store, whose file I/O runs on
//     BackgroundWork's files lane; plans/cmux-next/chrome-parity/p12-perf-process.md section 3.9)
//   CmuxNextMemory -> Compat only (the memory coordinator, budgets from RAM and the memory report; the consumer
//     protocol and traits live in Compat so any module registers a consumer with no new edge; p07-memory.md)
//   CmuxNextInputCore -> Compat, swift-atomics (input latency: event kinds, stages, open-slot table, closed-slot
//     ring, buckets; no AppKit; plans/cmux-next/chrome-parity/p04-input.md section 3; Compat's Atomic for
//     the counters, swift-atomics for the table's packed UnsafeAtomic storage, which Compat's Atomic cannot lay out)
//   CmuxNextOracle -> system frameworks only (the refactor oracle's facet providers, the one immutable list the
//     composition root builds and the snapshot capture; Control serves it as debug.oracle.snapshot;
//     every source is under DEBUG || CMUX_BENCH_HOOKS, so Release builds an empty module; p15-oracle.md section 3A)
//   CmuxNextInput -> InputCore, Signposts, Wakeups (the one input tap: typed subscriptions by class, phase and window;
//     globalObserve; p04-input.md section 3 (A); PointerFrameConsumer.post(NSEvent) into Wakeups, (C);
//     InputLatencyTracker, Chrome's EventLatency over CommitBoundary and PresentationClock, the input.latency signpost,
//     and its sendEvent wiring, (I))
//   CmuxNextIPC -> CmuxNextWireDigest, Compat (the app-daemon wire; its bindings are built from cmux-tui/spec by
//     CmuxNextWireGenPlugin running the host tool CmuxNextWireGen, which shares that digest; p05-ipc.md section 3.3;
//     Compat's Mutex guards FrameWriter's priority FIFOs, task 055)
//   CmuxNextWireDigest -> nothing (FNV-1a 64, the schema digest CmuxNextIPC and CmuxNextWireGen share)
//   CmuxNextIcons -> system frameworks only (the cmux icon pack, catalog, renderer and Icon view)
//   CmuxNextChiefMemory -> Design (the built-in Memory Inspector: model and view; the App supplies its daemon-backed source)
//   CmuxNextSettings -> DesignTokens, Design, Actions (cmux.json load/watch/apply, SettingsSchema; Design only for
//     DesignSettings, toasts and backdrops until they move, MQ-settings-design)
//   CmuxNextSettingsWindow -> Settings, Design, Icons, Actions, Wakeups (Debug Settings, SwiftUI; Settings deep links and the string catalog the React Settings page reads)
//   CmuxNextControl -> Actions, Settings, Daemon, InputCore, Oracle (app control socket; no UI; Compat/ forwards cmux CLI verbs to cmux-tui;
//     InputBudget/ folds input latency batches off main)
//   CmuxNextCloud -> CMUXAuthCore, CmuxAuthRuntime (Stack auth, /api/vm REST,
//     WireGuard hub and cmux-tui remote links; no UI, no daemon)
//   CmuxNextRemote -> CmuxNextCloud (SSH machines: ssh argv, probe, install, relay policy; no UI, no daemon)
//   CmuxNextMobile -> Daemon, CMUXMobileCore, CmuxIrxTransport (phone host; no UI)
//   CmuxNextUpdater -> Design, Icons, CmuxUpdater, Sparkle (update checks, appcast probe, update sheet; no daemon)
//   CmuxNextMallocZone -> libSystem only (C: the delegating default malloc zone that lets the
//     Chromium framework load later from another thread; plans/cmux-next/browser-isolation.md)
//   CmuxNextRemoteLayer -> QuartzCore, AppKit only (ObjC headers: CALayerHost, the remote layer a layer-hosted
//     Chromium page draws through, plans/cmux-next/cef-layer-hosting-DESIGN.md; NSAccessibilityRemoteUIElement,
//     a hosted page's accessibility, chrome-parity/p01-process.md task 049)
//   CmuxNextBrowserImport -> system frameworks only (browser detection, parsers, importer; no UI)
//   CmuxNextBrowserHistory -> Browser, Daemon, Compat (a browser tab's saved history across relaunches; no UI)
//   CmuxNextOnboarding -> Design, Icons, BrowserImport (first-run window; the App supplies OnboardingServices)
//   CmuxNextHome -> Compat, Design, Dictation, Wakeups, MessagesLabHome (the Home transcript: MessagesLabAppKitNative's
//     vendored code over the shared HomeStore; no daemon; plans/cmux-next/home-mac.md),
//     MessagesLabSidebar (MessagesLab's conversation list, the v1 sidebar seam)
//   CmuxNextHomeEngine -> AgentPane, Actions, Cloud, Compat, Daemon, Design, Home, Icons, IPC, Wakeups,
//     CmuxHomeCore, CmuxAgentQuestion (Home sources, Chief host and migration, Home strings; the App
//     supplies HomeService over AppServices; IPC: the generated `cmux.protocol/2` requests, p05-ipc-047)
//   CmuxNextDaemonService -> Daemon, Actions, AgentPane, Apps, Compat, Control, Layout, Trace (HangWatch), Wakeups
//     (DaemonService: one machine's daemon connection, command funnels, launch snapshot; FrameBatcher;
//     the Refusals and Cloud strings it shows; no AppServices; the App sets its launch-mark hook)
//   CmuxNextFocusUI -> Actions, Design (AppKit overlays of keys: the shortcut hint overlay and capture
//     waiter, the which-key controller, overlay, rows and strings; the focus state machine, key rules
//     and key delivery stay in the App)
//   CmuxNextComputerUse -> AgentActivity, Compat, Settings, Wakeups (the macOS Computer Use helper:
//     launch, v2 helper and its disclaimed spawner, signed Unix peer checks, the cua helper manifest
//     reader; setup stays in the App)
//   CmuxNextHistory -> Design, Icons (history model, SQLite visit log, cmux://history page; no daemon)
//   CmuxNextStash -> Compat, Daemon, DaemonService, History (Stash on this Mac's daemon: the Stashed
//     page's source; the App answers StashHost)
//   CmuxNextPages -> Design, Settings (the one host for React pages: PageWebView, cmux-page://<id>/
//     scheme, engine-neutral bridge, PageRouter + PageProvider; no daemon; the App supplies providers;
//     plans/cmux-next/react-pages.md)
//   CmuxNextCodeRouter -> CmuxNextCloud (provider sign-in detection, the CodeRouter control-plane
//     client, pasted-key Keychain store, account row state; no UI, no daemon; plans/cmux-next/coderouter.md)
//   CmuxNextAccounts -> CodeRouter, Design, Icons, CmuxSafeConcurrency (Settings > Accounts and the onboarding step; the App supplies AccountsServices)
//   CmuxNextAgentIntegrations -> Daemon, Pages, Settings (Settings > Agents > Agent integrations: relays the bundled
//     CLI's `agent hook status|install|uninstall`; the App supplies the CLI's location)
//   CmuxNextBookmarks -> Design, Icons, Wakeups (bookmark tree per browser profile, Netscape HTML, ranking, file store,
//     cmux://bookmarks page, bookmarks bar, edit bubble; no daemon; the App supplies the store)
//   CmuxNextResources -> Wakeups, Design (hover-card CPU/memory: aggregation, on-demand sampler, lines;
//     no daemon; the App supplies the samples). Tabs and Sidebar show it.
//   CmuxNextAgentPane -> Design, Actions, Dictation (WKWebView host for the React agent pane and the acpmux
//     handshake; the page talks to acpmux itself; no daemon)
//   CmuxNextAgentCursor -> CmuxAgentCursor (vendored; agent cursor commands from input events and the layout)
//   CmuxNextAgentCursorVisibility -> AgentCursor (pure visibility rules for a cursor target: snapshot in,
//     visible / hidden anchor / not drawn out; no AppKit; the App builds the snapshot from the live models)
//   CmuxNextWorkspaceNaming -> Bridge, Compat, Daemon, DesignTokens (hq#1957: the name a workspace takes from a moved
//     tab or its front tab, and the one-time rename; pure rules; the App supplies its pages and the rename command)
//   CmuxNextAgentActivity -> Design (Agent activity pane: computer use sessions, timeline, prototype layouts;
//     a projection of the CUA host; no daemon; the App supplies the source; plans/cmux-next/computer-use.md)
//   CmuxNextAgentUpdates -> Actions, Compat, Daemon, DaemonService, Pages, Settings (Settings and palette agent CLI
//     updates as owner-bound terminal jobs: intents, receipts, outcomes; the App supplies the route glue)
//   CmuxNextFileGrid -> system frameworks only (the thumbnail grid: tiles, thumbnail cache, drag
//     out, drop reading, Quick Look and the command menu; it reads and changes no files)
//   CmuxNextScreenshots -> FileGrid, Files (the Screenshots pane: source detection for macOS and the
//     screenshot tools, reading, watching and file operations through CmuxNextFiles, the live model
//     and the pane view; no daemon; the App supplies the workspace)
//   CmuxNextAgentLanes -> AgentActivity, Apps, Bridge, Sidebar, Wakeups (the acpmux `_acpmux/watch` feed for turn
//     states and lanes, cx-v9k2f, the sidebar's Priority view and its Chief item with its App Store card)
//   CmuxNextApps -> Design, Icons, Wakeups (app platform: manifest model, scene store + native renderer, JavaScriptCore
//     prototype engine, prototype registry, App Store window; no daemon; the App supplies the
//     operation sink; plans/cmux-next/app-platform.md)
//   CmuxNextFocus -> CCmuxAppFFI (the window focus machine: focus state view, events, effects,
//     topology, and FocusMachine over cmux-focus-core's cmux_focus_* C ABI; no AppKit; cx-8w027.2)
//   CmuxNextTasks -> Design, Icons, CCmuxAppFFI (Tasks pane: list, board and inbox prototypes over a
//     mirror + intent log of the Tasks owner, whose reducer previews pending intents over the FFI;
//     no daemon; the App supplies the source; plans/cmux-next/tasks.md)
//   CmuxNextFeed -> Design, Wakeups (feed panel: list, inbox and menu bar prototypes over a mirror + intent
//     log of the feed owner; no daemon; the App supplies the source; plans/cmux-next/feed.md)
//   CmuxNextServer -> Design, Icons, Wakeups (server menubar panel, pairing, approver sheet and health prototypes
//     over a projection of `server.status`; no daemon; the App supplies the source;
//     plans/cmux-next/server.md)
//   CmuxNextRemoteView -> Design, Icons, Input, InputCore, Wakeups (remote desktop pane: decode, presenters, chrome, input capture;
//     no daemon; the App supplies the stream source and input sink; plans/cmux-next/remote-desktop.md)
//   CmuxNextMacScreen -> Compat, Settings, Wakeups, Actions, Control, Design, RemoteView, Devices, CmuxScreenKit (Mac Screen tabs: another
//     Mac's screen as a WebRTC stream, the user's devices from the device hub, pairing home page (DEV), Share This Mac host,
//     host approval prompt, Settings > Devices state; CmuxScreenKit links WebRTC.framework)
//   CmuxNextDevices -> Compat, Wakeups (the device hub: Secure Enclave device identity, the signed
//     HTTP client, the User DO socket, relay sealing and the @Observable DeviceHub; no UI; the App
//     supplies the account token and the hub URL; docs/device-hub/PROTOCOL.md)
//   CmuxVNC (Shared) -> system frameworks and libz only (RFB client; CmuxNextRemoteViewSessions adapts it to the pane
//     as a RemoteViewFrameSource for `via=vnc` records; remote-desktop.md 12)
//   CmuxNextRemoteViewSessions -> Compat, Design, Icons, Settings, Browser, RemoteView, RemoteBrowser, CmuxVNC,
//     CmuxVNCDemoServer (the remote_view browser tab and, in DEV builds, its live part: the mock desktop, the rd debug host, and `via=vnc`
//     with its source, input sink, saved sign-ins and sign-in sheet; the App makes one per tab)
//   CmuxNextServerHelper -> Compat (Mutex) and system frameworks (privileged helper XPC protocol,
//     fix allowlist, same-team listener; plans/cmux-next/server.md 9.4); the App links it for the client side
//   CmuxNextServerHelperDaemon -> ServerHelper (the root helper executable; bundled by
//     scripts/cmux-next/bundle-server-helper.sh, not linked into the App)
//   CmuxNextDictation -> Wakeups (on-device speech: SpeechAnalyzer, SFSpeechRecognizer fallback,
//     the session state machine; no UI)
//   CmuxNextErrorJournal -> system frameworks only (the bounded, deduplicated error journal
//     `cmux errors` reads: app log, page consoles, acpmux and Chief logs, crash reports)
//   CmuxNextFiles -> Compat, Wakeups (Files pane core: listing, FSEvents, file operations,
//     Undo, the pane model; no AppKit; plans/finder-parity/PARITY.md)
//   CmuxNextFilesUI -> Files, Design, Compat (the Files pane's AppKit views: list, icons, columns,
//     path bar, Quick Look, drag in and out)
//   CmuxNextCrashReporting -> CmuxSentryReporting, Sentry, Features (crash and exception reports to Sentry:
//     consent, channel environment, release, scrubbing, the launch's features; no UI, no daemon; cx-urd.58)
//   CmuxNextHangReports -> Compat, InputCore, Features, system frameworks, MetricKit (opt-in hang reports for
//     NIGHTLY: MetricKit, watchdog and input latency inputs, allow-list redaction, leak scan, rotating
//     install id, outbox, upload; no UI, no daemon; plans/cmux-next/hang-reports-DESIGN.md)

/// The compile-time safety settings every Swift target carries (plans/cmux-next/chrome-parity/p10-stability.md):
/// `.strictMemorySafety()`, then `.treatWarning("StrictMemorySafety", as: .error)` once its count is 0. SwiftPM 6.2
/// accepts both and names the group "StrictMemorySafety" (checked with 6.2.4). Empty until the settings lander
/// (scripts/cmux-next/stability-settings.json) fills it; guardrails.py's `target-settings` rule refuses a new
/// target without it.
let stabilitySwiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
]

/// Release-only profile-guided optimization of the CmuxNext Swift targets (plans/cmux-next/chrome-parity/p08-startup.md,
/// section F, task 052). `scripts/cmux-next/pgo/release-env.sh` (check-release-compile.sh and the Nightly's Release
/// build) sets `CMUX_PGO_PROFDATA` only when the switch in Resources/build/cmux-next.pgo.conf is on and the profile's
/// sha256 matches Resources/build/cmux-next.profdata.sha256, at a path that names that sha256, so a new profile is a
/// new flag. A flag here reaches this package's targets and no remote
/// package (startup-DESIGN.md section 9, `scope-xcodebuild`). `CMUX_PGO_COMPANIONS` adds task 110's adopted
/// variants (startup-DESIGN.md section 10), which ship only with the profile, as Chrome ships PGO only on ThinLTO.
let releaseProfileSwiftSettings: [SwiftSetting] = {
    guard let profile = Context.environment["CMUX_PGO_PROFDATA"], !profile.isEmpty else { return [] }
    let companionFlags: [String: String] = ["thinlto": "-lto=llvm-thin", "cmo": "-cross-module-optimization"]
    let companions = (Context.environment["CMUX_PGO_COMPANIONS"] ?? "").split(separator: ",")
    let flags: [String] = ["-profile-use=\(profile)"] + companions.compactMap { companionFlags[String($0)] }
    return [.unsafeFlags(flags, .when(configuration: .release))]
}()

/// Settings shared by every UI target: Swift 6 mode, main-actor by default.
let uiSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
] + stabilitySwiftSettings + releaseProfileSwiftSettings

/// The daemon client is not main-actor by default: one actor owns the socket.
let daemonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
] + stabilitySwiftSettings + releaseProfileSwiftSettings

/// Exports of the pinned GhosttyNextKit (Packages/Shared/CmuxGhosttyKit) beyond the API every pin has,
/// as compile-time conditions of CmuxNextTerminal. libghostty links statically and Release exports no
/// symbols, so the app never looks one up at run time: the pin bump that brings an export turns its
/// condition on in the same commit, and a condition on without the export fails the compile and link.
/// - GHOSTTY_GPU_RESIDENT: `ghostty_surface_set_gpu_resident` (ghostty-next cp/p07-memory-036, not in
///   723c4ab93): `GhosttyGPUResidency`, so `terminalGPURelease` and the larger warm set.
/// - GHOSTTY_TRACE_HOOK: `ghostty_set_trace_hook` and `ghostty_surface_trace_id` (ghostty-next
///   cp/p09-observability-048, PR 57, not in 723c4ab93): `GhosttyTraceHook`, so `ghostty.render`,
///   `frame.gpu_done`, the contents mark and echo stages in Release builds.
/// - GHOSTTY_ENERGY_SAVER: `ghostty_app_set_energy_saver` (ghostty-next cp/p14-energy-114, not in
///   723c4ab93): `GhosttyRuntime.followEnergySaver(on:)` sends the saver's edges to libghostty.
/// - GHOSTTY_RENDERER_FRAMES: renderer-owned frames (ghostty-next cp/p03-rendering-080 f60815cf5, not in
///   723c4ab93): `void *ghostty_surface_presented_frame(ghostty_surface_t)` (an IOSurfaceRef, +1, NULL
///   before the first frame and after a purge; Swift sees `UnsafeMutableRawPointer?`),
///   `void ghostty_surface_set_presentation(ghostty_surface_t, ghostty_presentation_e)` with
///   `GHOSTTY_PRESENTATION_HIDDEN`, `_SHOWN`, `_PURGE`, and the surface config's
///   `ghostty_surface_presented_cb presented_cb` (userdata, frame id, host time, presented time) with
///   `presented_userdata`. CmuxNextTerminal reads, hides and purges frames through the first two
///   (`GhosttyFrameSource`), reads no layer contents, and takes each presented frame as its contents mark
///   (`ghosttySurfacePresented`, p03-rendering-081).
/// - GHOSTTY_PRESENT_NEVER_WAITS: `ghostty_surface_present_host_frame` never waits and orders its frame
///   against the renderer's by one sequence, and `ghostty_surface_render_counters_s` ends with
///   `host_superseded_presents` (ghostty-next cp/p03-rendering-084, not in 723c4ab93):
///   `TerminalHostFramePresenter` calls it ahead of each commit with a resized terminal.
/// - GHOSTTY_LOCK_WAIT: `ghostty_surface_set_lock_wait_callback` (ghostty-next cp/p04-input-078, not in
///   723c4ab93): `GhosttyLockWaitSignpost` records `ghostty.lock_wait` in Debug and bench builds.
/// - GHOSTTY_EXTERNAL_VSYNC: external vsync (ghostty-next cp/p03-rendering-082 7436f3b9a, not in 723c4ab93): the
///   surface config's `bool vsync_external`, `ghostty_surface_vsync_wanted_cb vsync_wanted_cb` and
///   `void *vsync_userdata`, and `void ghostty_surface_vsync(ghostty_surface_t)`. With a `VSyncHub` (feature
///   `vsyncHub`) each surface makes no display link and ticks from its display's hub thread while it draws and
///   wants frames (`TerminalVSync`, p03-rendering-083).
/// - GHOSTTY_EXTERNAL_CURSOR: the external cursor (ghostty-next cp/p03-rendering-090 1d35a0460, not in 723c4ab93):
///   the surface config's `bool cursor_external` (the renderer neither draws nor blinks the cursor),
///   `ghostty_surface_cursor_cb cursor_cb` and `void *cursor_userdata`. The callback,
///   `void (*)(void *userdata, const ghostty_cursor_cell_s *)`, comes once per move or change of the cursor cell,
///   never per blink, and never blocks. `ghostty_cursor_cell_s` has `uint64_t serial`, `void *surface` (an
///   IOSurfaceRef of the cell as Ghostty draws it; +0, valid for the call; NULL when not visible; a new surface per
///   cell), `uint32_t x, y, width, height` (the cell in the surface's pixels from the frames' top-left corner),
///   `uint16_t column, row`, `ghostty_cursor_cell_style_e style` (`GHOSTTY_CURSOR_CELL_BLOCK`, `_BLOCK_HOLLOW`,
///   `_BAR`, `_UNDERLINE`, `_LOCK`), `bool visible`, `bool blinking` and `uint32_t blink_interval_ms`. The pin
///   bump that turns this on also needs 090 to call `cursor_cb` inside the Core Animation transaction that
///   presents the cell's frame, on the presenting thread, after the frame's contents are set
///   (`IOSurfaceLayer.setSurfaceCallback` on main, `setSurfaceOffMain` on the GPU completion thread; a cell whose
///   frame is dropped goes with the next frame presented): 1d35a0460 calls it after the present, from
///   `frameCompleted`, so the cursor would not move with its text. `TerminalCursorLayer` shows it behind feature
///   `terminalCursorLayer` (p03-rendering-091).
let ghosttyNextKitHasGPUResident = false
let ghosttyNextKitHasTraceHook = false
let ghosttyNextKitHasEnergySaver = false
let ghosttyNextKitHasRendererFrames = false
let ghosttyNextKitHasPresentNeverWaits = false
let ghosttyNextKitHasLockWait = false
let ghosttyNextKitHasExternalVSync = false
let ghosttyNextKitHasExternalCursor = false
let ghosttyNextKitCapabilities: [SwiftSetting] =
    (ghosttyNextKitHasGPUResident ? [.define("GHOSTTY_GPU_RESIDENT")] : [])
    + (ghosttyNextKitHasTraceHook ? [.define("GHOSTTY_TRACE_HOOK")] : [])
    + (ghosttyNextKitHasEnergySaver ? [.define("GHOSTTY_ENERGY_SAVER")] : [])
    + (ghosttyNextKitHasRendererFrames ? [.define("GHOSTTY_RENDERER_FRAMES")] : [])
    + (ghosttyNextKitHasPresentNeverWaits ? [.define("GHOSTTY_PRESENT_NEVER_WAITS")] : [])
    + (ghosttyNextKitHasLockWait ? [.define("GHOSTTY_LOCK_WAIT")] : [])
    + (ghosttyNextKitHasExternalVSync ? [.define("GHOSTTY_EXTERNAL_VSYNC")] : [])
    + (ghosttyNextKitHasExternalCursor ? [.define("GHOSTTY_EXTERNAL_CURSOR")] : [])

/// The app's ONE Rust static library, CCmuxAppFFI (cmux-tui/crates/cmux-app-ffi):
/// the remote desktop core C ABI (module CCmuxRdFFI), the sidebar layout
/// reducer C ABI (module CCmuxLayoutReducerFFI) and the palette ranker C ABI
/// (module CCmuxPaletteRankerFFI) over one Rust runtime. Every
/// build links it from one pinned release
/// (.github/workflows/app-ffi-release.yml). Apple's compact unwind
/// holds at most three personality routines per image (C++, iroh, this one),
/// so a new in-tree C ABI joins cmux-app-ffi, never another static library
/// (scripts/cmux-next/check-app-personalities.sh fails the app build above
/// three). A pin change updates the URL (tag cmux-app-ffi-<source sha>) and the
/// checksum together; scripts/cmux-next/check-app-ffi-pin.sh fails CI
/// when the FFI sources differ from the pinned source sha.
let appFFI: Target = .binaryTarget(
    name: "CCmuxAppFFI",
    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-ecdb356418c355bbe8f16f883194748c47c28ebe/CCmuxAppFFI.xcframework.zip",
    checksum: "77731711f1088f285e168b27f0171363ea5bb619dc7b6e0e56464ff208dd18f4"
)

// Debug-only product consumed by Prototypes/UiLayerHost. Keeping this leaf
// separate from CmuxNextApp lets the host build real SwiftUI chrome without
// pulling in the app composition root.
let uiLayerPreviewProducts: [Product] = [
    .library(name: "CmuxNextUiLayerPreview", targets: ["CmuxNextUiLayerPreview"]),
]

let uiLayerPreviewTargets: [Target] = [
    .target(
        name: "CmuxNextUiLayerPreview",
        dependencies: ["CmuxNextDesign", "CmuxNextIcons"],
        swiftSettings: uiSwiftSettings + [
            .define("CMUX_UI_LAYER_PREVIEW", .when(configuration: .debug)),
        ]
    ),
    .testTarget(
        name: "CmuxNextUiLayerPreviewTests",
        dependencies: ["CmuxNextUiLayerPreview"],
        swiftSettings: uiSwiftSettings
    ),
]

let packageProducts: [Product] = [
    .library(name: "CmuxNextApp", targets: ["CmuxNextApp"]),
    .library(name: "CmuxNextFavicons", targets: ["CmuxNextFavicons"]),
    .library(name: "CmuxNextAppCore", targets: ["CmuxNextAppCore"]),
] + uiLayerPreviewProducts

let packageTargets: [Target] = uiLayerPreviewTargets + [
        .target(
            name: "CmuxNextAppCore",
            dependencies: ["CmuxNextActions", "CmuxNextAgentPane", "CmuxNextBridge", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextSidebar"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextApp",
            dependencies: [
                "CmuxNextAppCore",
                "CmuxNextChiefMemory",
                "CmuxNextCompat",
                "CmuxNextFavicons",
                "CmuxNextFeatures",
                "CmuxNextFiles",
                "CmuxNextFilesUI",
                "CmuxNextVSCodeServer",
                "CmuxNextKeepAwake",
                "CmuxNextEnergy",
                "CmuxNextChromiumWarmup",
                "CmuxNextChromiumRuntime",
                "CmuxNextBrowserTabs",
                "CmuxNextPhoneAccess",
                "CmuxNextPhone",
                "CmuxNextPopups",
                "CmuxNextWorkspaceRepair",
                "CmuxNextCLIInstall",
                "CmuxNextMallocZone",
                "CmuxNextMemory",
                "CmuxNextProcessEnvironment",
                "CmuxNextCrashReporting",
                "CmuxNextHangReports",
                "CmuxNextSignposts",
                "CmuxNextErrorJournal",
                "CmuxNextDiff",
                "CmuxNextHome",
                "CmuxNextHomeEngine",
                "CmuxNextHostPressure",
                "CmuxNextHibernation",
                "CmuxNextLaunch",
                "CmuxNextChiefPetWiring",
                "CmuxNextHostedChief",
                "CmuxNextDaemonService",
                "CmuxNextAgentUpdates",
                "CmuxNextFocus",
                "CmuxNextFocusUI",
                "CmuxNextInput",
                "CmuxNextInputModel",
                "CmuxNextOracle",
                "CmuxNextInputDiagnostics",
                // The app-daemon wire (p05-ipc): the generated `cmux.protocol/2` requests History,
                // Home and the page relay send (task 047).
                "CmuxNextIPC",
                "CmuxNextComputerUse",
                "CmuxNextAgentQuestion",
                "CmuxNextAgentPermissions",
                "CmuxNextDaemonRecovery",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                // The signed approve answer format shared with the iPhone (cx-aocz).
                .product(name: "CmuxFeedPushCore", package: "CmuxFeedPushCore"),
                // The free tier's App Attest provider is composed here (cx-ds09i).
                .product(name: "CmuxAppAttest", package: "CmuxAppAttest"),
                // OnceContinuation, the continuation that resumes exactly once (p10-stability-083/084).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                "CmuxNextWakeups",
                "CmuxNextActions",
                "CmuxNextDaemon",
                "CmuxNextDesign",
                "CmuxNextIcons",
                "CmuxNextTerminal",
                "CmuxNextTerminalGeometry",
                "CmuxNextTerminalFind",
                "CmuxNextTabs",
                "CmuxNextSidebar",
                "CmuxNextSidebarActions",
                "CmuxNextPalette",
                "CmuxNextLayout",
                "CmuxNextBrowser",
                "CmuxNextBrowserHistory",
                "CmuxNextBrowserAutomation",
                "CmuxNextBrowserHost",
                "CmuxNextRemoteFetch",
                "CmuxNextRemoteLocalhost",
                "CmuxNextRemoteLocalhostService",
                "CmuxNextBridge",
                "CmuxNextControl",
                "CmuxNextSettings",
                "CmuxNextSettingsWindow",
                "CmuxNextCloud",
                "CmuxNextRemote",
                "CmuxNextMobile",
                "CmuxNextMobileHost",
                "CmuxNextUpdater",
                "CmuxNextWebUpdates",
                "CmuxNextResources",
                "CmuxNextBrowserImport",
                "CmuxNextOnboarding",
                "CmuxNextCookieImport",
                "CmuxNextImportCards",
                "CmuxNextImportSuggestions",
                "CmuxNextAgentPane",
                "CmuxNextHistory",
                "CmuxNextPages",
                "CmuxNextRemoteView",
                "CmuxNextRemoteBrowser",
                "CmuxNextMacScreen",
                "CmuxNextDevices",
                "CmuxNextRemoteViewSessions",
                "CmuxNextCodeRouter",
                "CmuxNextAccounts",
                "CmuxNextAgentIntegrations",
                "CmuxNextBookmarks",
                "CmuxNextAgentActivity",
                "CmuxNextScreenshots",
                "CmuxNextAgentLanes",
                "CmuxNextChiefViews",
                "CmuxNextAgentCursor",
                .product(name: "CmuxAgentCursor", package: "CmuxAgentCursor"),
                "CmuxNextAgentCursorVisibility",
                "CmuxNextWorkspaceNaming",
                "CmuxNextApps",
                "CmuxNextTasks",
                "CmuxNextServer",
                "CmuxNextServerHelper",
                "CmuxNextFeed",
                "CmuxNextNowPlaying",
                "CmuxNextFloating",
                "CmuxNextStash",
                // The window focus rules (cmux-focus-core) run in-process over the app FFI.
                "CCmuxAppFFI",
                "CmuxNextTrace",
                "CmuxNextMetrics",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Surfaces that float over every app and Space: the Chief pet (its panel, notice bubble
        // and feed) and the floating chat's per-display frames. Wiring stays in the App.
        .target(
            name: "CmuxNextFloating",
            // CmuxNextInput: the pet's drag posts to its panel's frame-aligned pointer input (p04-input-089).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The Chief pet's glue outside the App (code-quality SW14): its rows in the Chief Settings
        // popover (Show Chief Pet, Pet Character) and the notice it makes from a daemon notification.
        .target(
            name: "CmuxNextChiefPetWiring",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextFloating", "CmuxNextSettings",
                           "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextFloatingTests",
            // CmuxNextWakeups: the pet's AppEvents and the scheduler its setting follow posts on (p06-scheduler-337).
            // WakeupsTestSupport: ChiefPetDragFramesTests' fake-link coalescer.
            dependencies: ["CmuxNextFloating", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // Archive and Unarchive of sidebar items (plans/cmux-next/archiving-DESIGN.md): the actions
        // on the sidebar document; the App only answers `SidebarArchiveHost`.
        .target(
            name: "CmuxNextSidebarActions",
            dependencies: ["CmuxNextActions", "CmuxNextSidebar"],
            resources: [.process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        // The Now Playing sources (cx-ouoxo): the playing browser tab, cmux's player, other apps
        // through macOS Now Playing, the card's feed, and the New Tab page's player (AgentPane).
        .target(
            name: "CmuxNextNowPlaying",
            dependencies: ["CmuxNextActions", "CmuxNextAgentPane", "CmuxNextBrowser", "CmuxNextCompat", "CmuxNextSettings", "CmuxNextSidebar", "CmuxNextWakeups", "CmuxNextTrace"],
            swiftSettings: uiSwiftSettings
        ),
        // Stash (a native OneTab, cx-rws36): the Stashed page's source on this Mac's daemon.
        // The App only answers `StashHost`.
        .target(
            name: "CmuxNextStash",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextHistory", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Agent pane (plans/cmux-next roadmap Phase 1): hosts the React pane
        // from webviews/src/agent-session/acpmux, built into
        // Resources/agent-pane by scripts/cmux-next/build-agent-pane-web.sh,
        // and answers its versioned handshake (find or start acpmux, endpoint,
        // token, session id). Everything above the handshake is TypeScript.
        .target(
            name: "CmuxNextAgentPane",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextErrorJournal", "CmuxNextActions", "CmuxNextDictation", "CmuxNextHibernation", "CmuxNextPages", "CmuxNextRemoteFetch", "CmuxNextSettings", "CmuxNextWakeups",
                           "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts", "CmuxNextInput",
                           .product(name: "CmuxAppAttest", package: "CmuxAppAttest"),
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/agent-pane"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAgentPaneTests",
            dependencies: ["CmuxNextAgentPane", "CmuxNextDaemon", "CmuxNextActions", "CmuxNextCompat", "CmuxNextDesign", "CmuxNextDictation", "CmuxNextInput", "CmuxNextPages", "CmuxNextPagesTestSupport", "CmuxNextRemoteFetch", "CmuxNextSettings", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts",
                           "CmuxNextTestSupport", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: uiSwiftSettings
        ),
        // Dictation (the composer's mic): the on-device speech engines and
        // the session state machine. Engines are actors fed by a real-time
        // audio tap, so the module is not main-actor by default.
        .target(
            name: "CmuxNextDictation",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        // Icons (design/icons): the cmux icon pack and catalog generated by
        // scripts/icons/build_pack.py, the path parser and renderer, the
        // SwiftUI `Icon` view and template NSImages. A leaf: no dependencies.
        .target(
            name: "CmuxNextIcons",
            dependencies: ["CmuxNextCompat"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // CodeRouter and provider accounts (plans/cmux-next/coderouter.md):
        // presence-only detection of local sign-ins (Codex, Claude Code, API
        // keys, clouds, local servers), the /api/coderouter control-plane
        // client, the pasted-key Keychain store and the row state machine.
        .target(
            name: "CmuxNextCodeRouter",
            dependencies: ["CmuxNextCompat", "CmuxNextCloud"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextCodeRouterTests",
            dependencies: ["CmuxNextCodeRouter"],
            swiftSettings: daemonSwiftSettings
        ),
        // The Accounts screen (Settings > Accounts, onboarding step). The App
        // supplies `AccountsServices`.
        .target(
            name: "CmuxNextAccounts",
            // CmuxSafeConcurrency: OnceContinuation for a pasted key's save answer (p02-threads-054..055).
            dependencies: ["CmuxNextCloud", "CmuxNextCodeRouter", "CmuxNextDesign", "CmuxNextIcons", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                           .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Localizable.xcstrings"),
                // BillingStrings (table Billing): moved from the App with Billing/ in B1.
                .process("Resources/Billing.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Browser import (onboarding step 2; data-model.md 5): source detection
        // (Chrome, Arc, Dia, Brave, Edge, Vivaldi, Helium, Chromium, Safari,
        // Firefox), parsers for bookmarks, history, open tabs and extensions,
        // and the cancellable importer. No UI, nothing main-actor.
        // A browser tab's saved history across relaunches: the writer that stores a page's
        // entries (and this Mac's engine state) with its daemon tab, and the restored pages
        // that start from it (cx-p0im9). Kept out of the App target (SW14).
        .target(
            name: "CmuxNextBrowserHistory",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-171).
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextBrowser", "CmuxNextWakeups",
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextBrowserImport",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            // browser-sources.json: the one browser source registry (decision
            // BOOKMARKS-IMPORT-EVERY-BROWSER I1).
            resources: [
                .copy("Resources/browser-sources.json"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // First-run onboarding window: theme and density, browser import,
        // default browser and terminal handlers, the key ideas tour. The App
        // supplies `OnboardingServices`.
        // Import Cookies from Browser for the CLI and agents (`browser.importCookies`):
        // the agent consent panel and the import. The App supplies `CookieImportHost`.
        .target(
            name: "CmuxNextCookieImport",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextActions", "CmuxNextBrowser", "CmuxNextBrowserImport", "CmuxNextDesign", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Import suggestion cards (Home, New Tab, Settings › Import): what this Mac has that cmux
        // can bring over, found from folder listings only, the dismissals, the Chief's requests and
        // the resumable import jobs. Pure model, no UI.
        .target(
            name: "CmuxNextImportSuggestions",
            dependencies: ["CmuxNextBrowserImport"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextImportSuggestionsTests",
            dependencies: ["CmuxNextImportSuggestions", "CmuxNextBrowserImport"],
            swiftSettings: daemonSwiftSettings
        ),
        // Corrupted Chrome, Firefox and Safari profiles through every import reader (p10-stability-025).
        .testTarget(
            name: "CmuxNextBrowserImportTests",
            dependencies: ["CmuxNextBrowserImport", "CmuxNextCompat", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        // The cards' center: the scan schedule, the job runner and the `import.*` actions, for
        // Settings › Import (no Home or New Tab suggestion). The App supplies `ImportCardsHost`.
        .target(
            name: "CmuxNextImportCards",
            dependencies: ["CmuxNextActions", "CmuxNextBrowserImport", "CmuxNextCompat", "CmuxNextDesign",
                           "CmuxNextImportSuggestions", "CmuxNextOnboarding", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextOnboarding",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextBrowserImport", "CmuxNextTrace", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The agent question card (plans/cmux-next/agent-questions.md): one
        // AppKit view and layout for Home rows, agent panes and the UI Gallery.
        // The launch window's connecting and failure screen with Retry Now and
        // Restart cmux-tui (cx-jniyz.1).
        .target(
            name: "CmuxNextDaemonRecovery",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextDesign", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Agent permission requests (plans/cmux-next/agent-permissions-DESIGN.md): the request
        // store, the reason check, computer use onboarding flow, the card, panel and mock TCC probe.
        .target(
            name: "CmuxNextAgentPermissions",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAgentPermissionsTests",
            dependencies: ["CmuxNextAgentPermissions", "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextAgentQuestion",
            dependencies: [
                "CmuxNextDesign",
                "CmuxNextIcons",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Chromium's EarlyMallocZoneRegistration, run first thing in main.
        .target(name: "CmuxNextMallocZone"),
        // QuartzCore's CALayerHost and AppKit's NSAccessibilityRemoteUIElement, declared for typed calls
        // (layer-hosted Chromium pages, their remote accessibility).
        .target(name: "CmuxNextRemoteLayer", linkerSettings: [.linkedFramework("QuartzCore"), .linkedFramework("AppKit")]),
        // Home (plans/cmux-next/home.md section 3): the native conversation
        // renderer (paged window, prefix-sum layout, background raster,
        // render-server send motion), the conversation list and composer.
        .target(
            name: "CmuxNextHome",
            dependencies: [
                "CmuxNextCompat", "CmuxNextDesign", "CmuxNextDictation", "CmuxNextIcons", "CmuxNextWakeups",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "MessagesLabHome", package: "CmuxMessagesLab"),
                .product(name: "MessagesLabSidebar", package: "CmuxMessagesLab"),
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Home engine (moved out of CmuxNextApp/Home): the Home sources (daemon, Cloud,
        // router), the Chief brain host, migration and sidebar models, and the Home
        // string catalog. No AppServices; the App's HomeService wires it.
        .target(
            name: "CmuxNextHomeEngine",
            // CmuxNextIPC: the generated `cmux.protocol/2` requests of the Chief owner calls (p05-ipc-047).
            // CmuxNextLaunch: the Home list's launch read lands on a LaunchReadEvent (p08-startup-076).
            dependencies: [
                "CmuxNextAgentPane", "CmuxNextActions", "CmuxNextCloud", "CmuxNextCompat",
                "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextHome", "CmuxNextIcons", "CmuxNextIPC", "CmuxNextLaunch", "CmuxNextWakeups",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                // OnceContinuation (p10-stability-083/088).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                "CmuxNextTrace",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The Cloud Home source over a fake daemon client (no daemon, no app): the server
        // choice's lease, Cloud attachments, and pin and mute of Cloud conversations.
        .testTarget(
            name: "CmuxNextHomeEngineTests",
            dependencies: [
                "CmuxNextHomeEngine", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextIPC", "CmuxNextWakeups",
                // ManualClock: PageCallDeadlineTests' deadline (p10-stability-171).
                "CmuxNextWakeupsTestSupport",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // Hosted Chief (Lawrence 2026-10-19): the Hosted Chief is the default Chief in Home;
        // the one-time copy of this Mac's Chief into it, its brain check, the cloud Chief
        // models and the Chief switch. No AppServices; the App's HomeService wires it.
        .target(
            name: "CmuxNextHostedChief",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextHomeEngine"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Daemon service (moved out of CmuxNextApp): one machine's cmux-tui daemon
        // connection and its command funnels, the frame batcher, and the Refusals and
        // Cloud strings it shows. No AppServices; the App sets `DaemonService.launchMark`.
        .target(
            name: "CmuxNextDaemonService",
            dependencies: [
                "CmuxNextActions", "CmuxNextAgentPane", "CmuxNextApps", "CmuxNextBridge", "CmuxNextCompat", "CmuxNextControl",
                "CmuxNextDaemon", "CmuxNextLayout", "CmuxNextTrace", "CmuxNextWakeups",
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // AppKit overlays of keys (moved out of CmuxNextApp/Focus): the shortcut hint
        // overlay and its capture waiter, the which-key controller, overlay, rows and
        // the WhichKey strings. The key rules and key delivery stay in the
        // App; the focus state machine is CmuxNextFocus.
        // The window focus machine (plans/cmux-next/focus.md section 4): the
        // read view of the focus state, its events, effects and topology,
        // and FocusMachine, the typed C ABI of cmux-focus-core (the state
        // and rules live in Rust; cx-8w027.2). No AppKit, no app imports.
        .target(
            name: "CmuxNextFocus",
            dependencies: ["CCmuxAppFFI"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextFocusUI",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextActions", "CmuxNextDesign", "CmuxNextSignposts", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The macOS Computer Use helper (moved out of CmuxNextApp/ComputerUse): helper
        // launch, the v2 helper and its disclaimed spawner, the cua helper manifest
        // reader. Setup (ComputerUseSetup) stays in the App.
        .target(
            name: "CmuxNextComputerUse",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextAgentActivity", "CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        // Resource usage for hover cards and `resources` (CPU and memory per
        // tab, per workspace, shared processes apart). Pure aggregation and a
        // sampler that runs only while a card is open.
        // History (plans/cmux-next/history.md): the location trail, merged
        // history entries, search, agent sessions from the session journal,
        // the per-profile page visit log (SQLite), and the cmux://history page.
        .target(
            name: "CmuxNextHistory",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // DNS-pinned HTTPS fetches for untrusted page-selected resources. Shared by browser
        // favicons, markdown remote images, and Agent reply media without coupling their domains.
        .target(
            name: "CmuxNextRemoteFetch",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        // React pages (plans/cmux-next/react-pages.md): one WKWebView host, one cmux-page://<id>/
        // origin per page, the cmuxPage bridge and the page router. Pages ship as one self-contained
        // index.html each under Resources/pages (scripts/cmux-next/build-pages-web.sh).
        .target(
            name: "CmuxNextPages",
            // Hibernation: PageLifecyclePlanner, the pure plan PageLifecycle performs (p13-webui-022).
            // InputCore: the quiet-input wait of the Settings, History and Cloud preload (PagePreloads, p13-webui-045).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextErrorJournal", "CmuxNextHibernation", "CmuxNextInputCore", "CmuxNextSettings", "CmuxNextWakeups", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts",
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [.copy("Resources/pages"), .process("Localizable.xcstrings")],
            swiftSettings: uiSwiftSettings
        ),
        // The one test double of PageChromiumPage / PageChromiumHosting, for every test target
        // that shows a page in Chromium: a protocol change edits one fake, compiled by the
        // protocol's own tests (a private copy in CmuxNextAgentPaneTests broke the test build).
        .target(
            name: "CmuxNextPagesTestSupport",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextPages", "CmuxNextSettings", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPagesTests",
            dependencies: ["CmuxNextCompat", "CmuxNextHibernation", "CmuxNextInputCore", "CmuxNextInputCoreTestSupport", "CmuxNextMemory", "CmuxNextPages", "CmuxNextPagesTestSupport", "CmuxNextSettings", "CmuxNextDesign", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts", "CmuxNextWakeups",
                           "CmuxNextTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // Settings > Agents > Agent integrations: the coding-agent hooks the bundled CLI
        // installs (`cmux agent hook`). The App supplies the CLI's location.
        .target(
            name: "CmuxNextAgentIntegrations",
            dependencies: ["CmuxNextDaemon", "CmuxNextPages", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAgentIntegrationsTests",
            dependencies: ["CmuxNextAgentIntegrations", "CmuxNextPages", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        // Bookmarks (plans/cmux-next/bookmarks.md): the tree per browser
        // profile, Netscape HTML import/export, omnibar ranking, the local
        // file store, the cmux://bookmarks page, the bookmarks bar and the
        // edit bubble.
        .target(
            name: "CmuxNextBookmarks",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextInput", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Agent cursor (plans/cmux-next/agent-cursor.md, R130): maps published
        // automation.input events through the live layout to cursor commands
        // for the window overlay. No layers, no timers; the App supplies the
        // resolver and the layer host.
        .target(
            name: "CmuxNextAgentCursor",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", .product(name: "CmuxAgentCursor", package: "CmuxAgentCursor")],
            swiftSettings: uiSwiftSettings
        ),
        // Agent cursor visibility (agent-cursor.md section 3, decisions
        // CURSOR-HIDDEN/SHOW/SCREENS): pure rules over a value snapshot,
        // replayed from schemas/agent-cursor-visibility/vectors.json.
        .target(
            name: "CmuxNextAgentCursorVisibility",
            dependencies: ["CmuxNextAgentCursor"],
            swiftSettings: uiSwiftSettings
        ),
        // Workspace naming (hq#1957): the name a workspace made from a moved tab
        // takes, and the name a default-named workspace takes from its front tab
        // (live label, or variant B's one-time rename). Pure rules; the App
        // supplies its browser pages, New Tab pages and the rename command.
        .target(
            name: "CmuxNextWorkspaceNaming",
            // CmuxNextWakeups: the auto-namer's follow is a ServiceObservation (p06-scheduler-339).
            dependencies: ["CmuxNextBridge", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesignTokens", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWorkspaceNamingTests",
            // CmuxNextWakeups: WorkspaceAutoNamerFollowTests runs the namer's follow on a test scheduler.
            dependencies: ["CmuxNextWorkspaceNaming", "CmuxNextBridge", "CmuxNextDaemon", "CmuxNextSidebar", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Phone tabs (plans/cmux-next/phone.md): simulators through simctl, real
        // iPhones through devicectl, recordings and feedback clips. No daemon,
        // no UI framework beyond AppKit; the App supplies the page and the sink.
        .target(
            name: "CmuxNextPhone",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPhoneTests",
            dependencies: ["CmuxNextPhone", "CmuxNextCompat", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport",
                           .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            resources: [.copy("Fixtures")],
            swiftSettings: daemonSwiftSettings
        ),
        // Files (u2360, plans/finder-parity/PARITY.md): the Finder-parity file browser's core.
        // Off-main getattrlistbulk listing, Finder name order, FSEvents per item, file
        // operations with conflict answers and Undo, and the pane model. No AppKit; the
        // Screenshots pane and the Files pane both read folders through it.
        .target(
            name: "CmuxNextFiles",
            // Compat: the FSEvents callback's CallbackRegistry (p10-stability-081).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextFilesTests",
            // CmuxFuzzSupport: FilePathFuzzTests (p10-stability-030).
            dependencies: ["CmuxNextFiles", "CmuxNextWakeups", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        // The Files pane's AppKit views over CmuxNextFiles: list (NSTableView), icons
        // (NSCollectionView), columns (NSBrowser), path bar, Quick Look, drag in and out,
        // the shared icon and thumbnail cache. The App hosts it as an internal page.
        .target(
            name: "CmuxNextFilesUI",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextFiles", "CmuxNextDesign", "CmuxNextCompat", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Keep awake (sessions.keepAwake): one idle-sleep hold for the Keep Mac Awake
        // action and working local agents, released on battery unless the user
        // chose Always. The App pushes the power source in (from CmuxNextEnergy), no polling.
        .target(
            name: "CmuxNextKeepAwake",
            dependencies: ["CmuxNextBridge", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextKeepAwakeTests",
            dependencies: ["CmuxNextKeepAwake", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Energy Saver's power inputs (plans/cmux-next/chrome-parity/p14-energy.md D): Low Power Mode,
        // IOKit's power source and battery charge, the thermal state, each observed once for the app
        // by EnergyMonitor, and EnergyPolicyResolver, which turns them and energy.saver into the saver's
        // reason (EnergySaverMode and EnergyPolicy are core values in CmuxNextWakeups). Only CmuxNextApp
        // (the composition root) depends on it.
        .target(
            name: "CmuxNextEnergy",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextEnergyTests",
            // CmuxNextPalette: EnergyActionsTests lists the palette's rows through RegistryPaletteProvider.
            dependencies: ["CmuxNextActions", "CmuxNextEnergy", "CmuxNextPalette", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Host pressure (cmuxterm-hq#2995): the shared host budget's verdict (acpmux's
        // `host_pressure`, else the same formula locally) as a level that does not flicker.
        // Memory pressure from the app's one MemoryPressureEvents (Compat, injected as a subscription),
        // plus one 15 s timer for load and swap.
        .target(
            name: "CmuxNextHostPressure",
            dependencies: ["CmuxNextCompat", "CmuxNextTrace", "CmuxNextMetrics"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextHostPressureTests",
            dependencies: ["CmuxNextHostPressure", "CmuxNextCompat", "CmuxNextTrace", "CmuxNextMetrics"],
            swiftSettings: daemonSwiftSettings
        ),
        // The memory coordinator (plans/cmux-next/chrome-parity/p07-memory.md section 3.A): one per
        // process, a port of Chrome's base/memory_coordinator over the consumer protocol and traits in
        // CmuxNextCompat/Memory. Near a leaf: it depends on CmuxNextCompat and on CmuxNextWakeups (the
        // footprint emitter's one-shot DemandTimer), and only the App imports it.
        .target(
            name: "CmuxNextMemory",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextInputCore", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextMemoryTests",
            dependencies: ["CmuxNextCompat", "CmuxNextInputCore", "CmuxNextInputCoreTestSupport", "CmuxNextMemory", "CmuxNextWakeups",
                           "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // VS Code (Inline): the one `serve-web` server on 127.0.0.1 behind Open Folder in VS Code
        // (Inline) and Stop/Restart VS Code Inline Server. The App opens its URL in a browser tab.
        .target(
            name: "CmuxNextVSCodeServer",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextVSCodeServerTests",
            dependencies: ["CmuxNextVSCodeServer"],
            swiftSettings: daemonSwiftSettings
        ),
        // Chromium warm start: maps the framework and runs CefInitialize and the
        // spare window at idle moments once a Chromium tab is likely. The App
        // supplies the signals (AppServices+Chromium).
        // Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md section 6):
        // download, verify and install the pinned Chromium runtime pack. A leaf
        // service: Foundation, Security, Network and CryptoKit, plus Wakeups for
        // TracedTask (p09-observability task 124); the App feeds its state to
        // CmuxNextBrowser's CEFRuntimeSource.
        .target(
            name: "CmuxNextChromiumRuntime",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChromiumRuntimeTests",
            dependencies: ["CmuxNextChromiumRuntime", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport"],
            swiftSettings: daemonSwiftSettings
        ),
        // Browser tabs (the App's browser tab domain, moved out leaf-first): the engine a new tab
        // gets (BrowserEngineResolver) and where it goes (BrowserTabRoute). Pure; the App composes it.
        // CmuxNextOracle: the tabs facet's values read through BrowserTab (DEV and bench only).
        .target(
            name: "CmuxNextBrowserTabs",
            dependencies: ["CmuxNextBrowser", "CmuxNextDaemon", "CmuxNextSettings", "CmuxNextOracle"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextChromiumWarmup",
            dependencies: ["CmuxNextBrowser", "CmuxNextCompat", "CmuxNextInputCore", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChromiumWarmupTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextChromiumWarmup", "CmuxNextCompat", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextInputCoreTestSupport", "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // Phone access (Settings > Accounts > Phone Access): the phone host's lifecycle
        // behind phone.allowConnections, the start-workspaces gate and the one-time
        // migration. The App supplies the account and the Mac's name.
        .target(
            name: "CmuxNextPhoneAccess",
            dependencies: ["CmuxNextCompat", "CmuxNextControl", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextKeepAwake",
                           "CmuxNextMobile", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPhoneAccessTests",
            dependencies: ["CmuxNextPhoneAccess"],
            swiftSettings: uiSwiftSettings
        ),
        // Browser popup panels: sized `window.open` popups (OAuth, payment) and
        // extension popup windows over their opener's window. The App routes page intents.
        .target(
            name: "CmuxNextPopups",
            dependencies: ["CmuxNextBrowser", "CmuxNextCompat", "CmuxNextDesign", "CmuxNextInput", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPopupsTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextDesign", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextPopups", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // The one owner of what happens to a workspace with no pane: a last-tab
        // close closes it, a lost terminal is refilled. The App supplies the
        // daemon's create and close (`EmptyWorkspaceRepair(daemon:)`).
        .target(
            name: "CmuxNextWorkspaceRepair",
            // CmuxNextWakeups: the repair's follows are ServiceObservations (p06-scheduler-339).
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWorkspaceRepairTests",
            // CmuxNextWakeups: the tests run the repair's follows on a scheduler whose turns they run by hand.
            dependencies: ["CmuxNextDaemon", "CmuxNextWakeups", "CmuxNextWorkspaceRepair"],
            swiftSettings: uiSwiftSettings
        ),
        // Agent activity (plans/cmux-next/computer-use.md section 7): the
        // pane listing computer use sessions on every machine, their
        // screenshot timeline and user controls. A projection: the CUA host
        // owns every session; the App supplies the source.
        .target(
            name: "CmuxNextAgentActivity",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-171).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CmuxNextTrace",
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/agent-activity"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The thumbnail grid: tiles, the thumbnail cache, drag out, drop reading, Quick Look and the
        // command menu. It reads and changes no files (CmuxNextFiles does). System frameworks and
        // CmuxNextCompat only (the thumbnail cache is a memory consumer).
        .target(
            name: "CmuxNextFileGrid",
            // Wakeups: each tile's thumbnail lands as a posted visible task (MainWorkScheduler).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The Screenshots pane (cmux://screenshots): macOS and screenshot-tool folders, live.
        .target(
            name: "CmuxNextScreenshots",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextFileGrid", "CmuxNextFiles", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextScreenshotsTests",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextFileGrid", "CmuxNextFiles", "CmuxNextScreenshots", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // The built-in Memory Inspector (plans/cmux-next/memory-inspector-native-DESIGN.md):
        // one Chief's memory read and changed through a ChiefMemorySource (the app's goes
        // over its daemon connection); model and SwiftUI view, no daemon or AppKit types.
        .target(
            name: "CmuxNextChiefMemory",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChiefMemoryTests",
            dependencies: ["CmuxNextChiefMemory"],
            swiftSettings: uiSwiftSettings
        ),
        // The Chief view gallery (webviews/src/pages/chief-views): the page's provider over the
        // agent lanes, terminal hook agents, the CI fleet dashboard and GitHub search, its Debug
        // Settings toggle and strings. The App passes its machines and navigation (ChiefViewsHost).
        .target(
            name: "CmuxNextChiefViews",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxNextActions",
                "CmuxNextAgentActivity",
                "CmuxNextBridge",
                "CmuxNextCompat",
                "CmuxNextDaemon",
                "CmuxNextDaemonService",
                "CmuxNextDesign",
                "CmuxNextHome",
                "CmuxNextPages",
                "CmuxNextSettings",
                "CmuxNextWakeups",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChiefViewsTests",
            dependencies: ["CmuxNextAgentActivity", "CmuxNextChiefViews", "CmuxNextCompat", "CmuxNextPages", "CmuxNextPagesTestSupport", "CmuxNextSettings",
                           "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // The acpmux watch feed (turn states and lanes), the sidebar's top items (Lanes, cx-v9k2f), its Chief item
        // (with its App Store card, Chief in Sidebar) and the Chief's tools in the docked Home's tab row.
        .target(
            name: "CmuxNextAgentLanes",
            dependencies: ["CmuxNextActions", "CmuxNextAgentActivity", "CmuxNextAgentPane", "CmuxNextApps", "CmuxNextBridge",
                           "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextHome", "CmuxNextHomeEngine",
                           "CmuxNextIcons", "CmuxNextSidebar", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // App platform (plans/cmux-next/app-platform.md): the cmux-app.json
        // model, the scene store and native renderer, the JavaScriptCore
        // prototype engine (DEV) that runs the engine-neutral runtime synced
        // from cmux-tui/crates/cmux-app-host by
        // scripts/cmux-next/sync-app-runtime.sh, the prototype app registry
        // and the App Store window. The App supplies the operation sink.
        .target(
            name: "CmuxNextApps",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextSettings", "CmuxNextWakeups"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/AppPlatform"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppsTests",
            dependencies: ["CmuxNextApps", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // App permissions (plans/cmux-next/first-party-apps.md sections 4 and 5):
        // tiers, sandbox profiles, grants and the pure policy, plus the consent
        // sheet, Settings > Apps > Permissions and first-use prompt prototypes.
        // No daemon; the App supplies the data source and the style setting.
        .target(
            name: "CmuxNextAppPermissions",
            dependencies: ["CmuxNextApps", "CmuxNextDesign", "CmuxNextIcons"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Tasks (plans/cmux-next/tasks.md): the pane over the team's Tasks
        // owner (a Rust service: cmux-tui/crates/cmux-tasks). A projection:
        // confirmed mirror + intent log; the App supplies the source.
        .target(
            name: "CmuxNextTasks",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CCmuxAppFFI", "CmuxNextTrace"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Feed panel (plans/cmux-next/feed.md section 12): list, inbox and
        // menu bar prototypes over a confirmed mirror + intent log of the
        // feed owner; the App supplies the source.
        .target(
            name: "CmuxNextFeed",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Remote desktop pane (plans/cmux-next/remote-desktop.md section 7):
        // VideoToolbox decode, presenter variants, chrome A, input capture and
        // a VideoToolbox mock host. Transport neutral. The App shows it in
        // `remote_view` tabs (cmux://remote-view records, development builds).
        .target(
            name: "CmuxNextRemoteView",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextWakeups", "CCmuxAppFFI", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts"],
            exclude: ["README.md"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The live part of a remote_view tab (DEV builds): the mock desktop,
        // the rd debug host, and `via=vnc` (CmuxVNC as the pane's frame source
        // and input sink, the Keychain sign-ins and the sign-in sheet).
        .target(
            name: "CmuxNextRemoteViewSessions",
            dependencies: [
                "CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextSettings", "CmuxNextBrowser", "CmuxNextRemoteView",
                "CmuxNextRemoteBrowser",
                .product(name: "CmuxVNC", package: "CmuxVNC"),
                .product(name: "CmuxVNCDemoServer", package: "CmuxVNC"),
                "CmuxNextWakeups",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Mac Screen tabs: another Mac's screen over a CmuxScreenKit stream
        // (WebRTC video, input on data channels), the pairing home page and
        // Share This Mac. Input capture comes from CmuxNextRemoteView.
        .target(
            name: "CmuxNextMacScreen",
            dependencies: ["CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups", "CmuxNextActions", "CmuxNextControl", "CmuxNextDesign", "CmuxNextRemoteView", "CmuxNextDevices", .product(name: "CmuxScreenKit", package: "CmuxScreenKit")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The device hub (docs/device-hub/PROTOCOL.md): this device's Secure
        // Enclave identity, the device-signed HTTP client, the User DO socket,
        // relay secret sealing and the DeviceHub model the UI reads. No UI.
        .target(
            name: "CmuxNextDevices",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextDevicesTests",
            dependencies: ["CmuxNextDevices", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextRemoteViewTests",
            dependencies: ["CmuxNextRemoteView", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport",
                           .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: uiSwiftSettings
        ),
        // Remote tab client (remote-tab.md r2): the page of a browser tab
        // whose runtime is on another machine. Decode and present come from
        // CmuxNextRemoteView; session state is the Rust client reducer.
        .target(
            name: "CmuxNextRemoteBrowser",
            dependencies: ["CmuxNextCompat", "CmuxNextRemoteView", "CmuxNextBrowser", "CmuxNextDesign", "CmuxNextInput", "CmuxNextInputCore", "CCmuxAppFFI", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // cmux server (plans/cmux-next/server.md sections 6, 9, 13, 14): the
        // menubar panel, pairing, approver sheet and health prototypes over a
        // projection of `server.status`. The App supplies the source.
        .target(
            name: "CmuxNextServer",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The cmux server's privileged helper (plans/cmux-next/server.md 9.4): the XPC
        // protocol, the fixed allowlist of fixes and the same-team listener. No UI.
        .target(
            name: "CmuxNextServerHelper",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        // The helper executable. The app bundle does not link it: the Xcode phase
        // "Bundle server helper" (scripts/cmux-next/bundle-server-helper.sh) compiles
        // these sources with swiftc into Contents/Resources/libexec/cmux-server-helper.
        .executableTarget(
            name: "CmuxNextServerHelperDaemon",
            dependencies: ["CmuxNextServerHelper"],
            swiftSettings: daemonSwiftSettings
        ),
        // The oracle's config suite, app side (p15-oracle-212): dumps the effective config of
        // every tests/oracle/corpus/config file; cmux-config's oracle_effective example dumps the
        // daemon side. An executable, not a test target; the app does not link it.
        .executableTarget(
            name: "OracleConfigDump",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextResources",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // Sparkle updates: channel/feed resolution, a read-only appcast probe
        // (dev builds and `updates.check`), and the update sheet.
        .target(
            name: "CmuxNextUpdater",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDesign",
                "CmuxNextIcons",
                "CmuxNextPages",
                "CmuxNextSettings",
                "CmuxNextWakeups",
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
                .product(name: "Sparkle", package: "Sparkle"),
                "CmuxNextTrace",
            ],
            // WhatsNew: the bundled What's New documents and media
            // (scripts/whats-new/sync-app-bundle.sh copies them from whats-new/).
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/WhatsNew"),
                // The keys a web update pointer may be signed with (plans/cmux-next/web-ota.md).
                .copy("Resources/web-update-keys.json"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Web updates in the app (plans/cmux-next/web-ota.md): serves a signed web update from
        // a safe point and answers `updates.web.*`.
        .target(
            name: "CmuxNextWebUpdates",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextAgentPane", "CmuxNextControl", "CmuxNextDesign", "CmuxNextPages", "CmuxNextSettings", "CmuxNextUpdater", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        // Cloud machines: auth, REST client, tunnel and link processes. The
        // App turns each connected machine's link socket into a DaemonService.
        .target(
            name: "CmuxNextCloud",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextWakeups",
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxInstallAuthCore", package: "CmuxInstallAuthCore"),
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
                "CmuxNextTrace",
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // Machines reached over the user's own OpenSSH: destinations, the
        // `cmux-tui remote connect ssh://` link, probe, reconnect gate, the
        // pinned cmux-tui install and the remote-to-local deny policy. No UI.
        .target(
            name: "CmuxNextRemote",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextCloud", "CmuxNextTrace", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        // The input model (p15-oracle-102): the terminal attach machine and the input journal's values, the input
        // observation and the model and transition invariants of plans/cmux-next/input-spec.md, as pure values and
        // rules with no AppKit, so replay and the oracle run them off the app (and on Linux). The journal ring, its
        // AppKit recorders and the key routing invariants (KeyRouter's tier rules) stay in the App.
        .target(
            name: "CmuxNextInputModel",
            dependencies: ["CmuxNextDaemon", "CmuxNextFocus"],
            swiftSettings: daemonSwiftSettings
        ),
        // App-layer mapping between daemon records and feature view models,
        // kept out of CmuxNextApp so it links in `swift test` (no GhosttyKit).
        .target(
            name: "CmuxNextBridge",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDaemon", "CmuxNextLayout", "CmuxNextSidebar", "CmuxNextTabs", "CmuxNextIcons",
                // TerminalAttachDriver runs CmuxNextInputModel's TerminalAttachMachine.
                "CmuxNextInputModel",
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                // OracleLayoutFacet (DEBUG || CMUX_BENCH_HOOKS): the layout facet from LayoutModel values.
                "CmuxNextOracle",
                "CmuxNextTrace",
                "CmuxNextWakeups",
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Back-ports of newer system APIs so that cmux-next runs on macOS 14
        // (plans/cmux-next/macos-floor.md): Mutex (CmuxSafeConcurrency's os_unfair_lock Mutex) and Atomic
        // (lock-free, swift-atomics) with the Synchronization API.
        .target(
            name: "CmuxNextCompat",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                // Mutex wraps the portable one (p10-stability-172), with the blocking detector as its wait observer.
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                // SharedThreadingBridge: the detector as the shared packages' blockingCall hook (p02-threads-130).
                .product(name: "CmuxThreading", package: "CmuxThreading"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextCompatTests",
            dependencies: [.target(name: "CmuxNextCompat"), .product(name: "CmuxThreading", package: "CmuxThreading")],
            swiftSettings: uiSwiftSettings
        ),
        // The error journal (`cmux errors`): one bounded, deduplicated NDJSON log of the
        // app's warnings, errors, faults and crashes, written off the main actor.
        .target(
            name: "CmuxNextErrorJournal",
            dependencies: ["CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextErrorJournalTests",
            dependencies: ["CmuxNextErrorJournal", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        // Always-on signpost intervals, one name catalog for Debug and Release benches
        // (plans/cmux-next/architecture-refactor-DESIGN.md section 7).
        .target(
            name: "CmuxNextSignposts",
            // Compat's Atomic: the MetricKit mirror's switch (SignpostMetricKitMirror.swift). Trace: the
            // typed ring trace points (Signposter+Trace.swift). Metrics: the key.frame and input.frame
            // histogram records of KeyFrameSignpost and InputFrameSignpost (p09-observability 054, 111).
            // SignpostsC: the key and stall signposts with no heap allocation (p09-observability 007).
            dependencies: ["CmuxNextCompat", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignpostsC"],
            swiftSettings: daemonSwiftSettings
        ),
        // os_signpost's C macros for the key and stall signposts: a stack buffer per emit, no heap allocation.
        // settings-allow: C target, no Swift sources (signposts.c); its C settings come from the lander's kind "c" rows
        .target(name: "CmuxNextSignpostsC"),
        // shm_open (variadic, so not callable from Swift) for the Chromium host control channel's
        // payloads over 64 KiB: a sealed read-only region (p01-process task 020).
        // settings-allow: C target, no Swift sources (shared_region.c, input_ring.c); its C settings come from the lander's kind "c" rows
        .target(name: "CmuxNextSharedRegionC"),
        .testTarget(
            name: "CmuxNextSignpostsTests",
            // Compat's Atomic: the allocation tests' per-thread malloc counter. SignpostsC: its names match the catalog.
            dependencies: ["CmuxNextSignposts", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextCompat", "CmuxNextSignpostsC"],
            swiftSettings: uiSwiftSettings
        ),
        // Launch-only types (plans/cmux-next/chrome-parity/p08-startup.md, task 073): CmuxNextApp's size
        // cap only goes down, so new launch code goes here and the App gets only the wiring. Never
        // depends on CmuxNextApp.
        .target(
            name: "CmuxNextLaunch",
            // Trace: LaunchMarks moves each mark's Date onto the trace clock through the launch's one LaunchClock pairing.
            // CmuxTheme: a window picture's theme fingerprint (WindowPictureMeta+Theme).
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextInputCore", "CmuxNextProfileRuntimeC",
                           "CmuxNextSignposts", "CmuxNextTrace", "CmuxNextWakeups", .product(name: "CmuxTheme", package: "CmuxTheme"),
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        // The compiler-rt profile runtime's C entry points for ProfileFlush (p08-startup task 103); only the
        // profile build (CMUX_PGO_PROFILE) imports it, so no other build references the symbols.
        // settings-allow: C header only, no Swift sources
        .target(name: "CmuxNextProfileRuntimeC"),
        .testTarget(
            name: "CmuxNextLaunchTests",
            // Compat, Signposts and Trace: LaunchReadEventTests reads the `launch.read_done` record of a test trace runtime;
            // LaunchCounterLogTests journals with Compat's Mutex.
            // Design: LaunchViewQueueTests gates a tab on a LaunchReveal pane region; BrowserLaunchPicturesTests holds the launch read with its own LaunchFileReader.
            dependencies: ["CmuxNextLaunch", "CmuxNextDesign", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport", "CmuxNextCompat",
                           "CmuxNextSignposts", "CmuxNextTrace", .product(name: "CmuxTheme", package: "CmuxTheme")],
            swiftSettings: uiSwiftSettings
        ),
        // Release tracing, hang watch and crash keys (plans/cmux-next/chrome-parity/p09-observability.md):
        // one TraceRuntime per process, like Chrome's TraceLog. Core: it depends only on Compat and swift-atomics.
        .target(
            name: "CmuxNextTrace",
            // swift-atomics: TraceRuntime's inlinable category check names its `UInt64: AtomicValue` conformance.
            dependencies: ["CmuxNextCompat", .product(name: "Atomics", package: "swift-atomics")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextTraceTests",
            // Compat: the black-box tests read the main-thread blocking detector's table.
            dependencies: ["CmuxNextCompat", "CmuxNextTrace"],
            // The ring v1 golden file, shared with cmux-trace's Rust tests; read by path, not bundled.
            exclude: ["Fixtures"],
            swiftSettings: daemonSwiftSettings
        ),
        // Field histograms (UMA): the HistogramID catalog and Metrics.record. Core: Compat and Trace only.
        .target(
            name: "CmuxNextMetrics",
            dependencies: ["CmuxNextCompat", "CmuxNextTrace"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextMetricsTests",
            dependencies: ["CmuxNextMetrics", "CmuxNextTrace", "CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextWakeups",
            // Signposts: the main-thread scheduler's `stall.main_task` and `stall.over_budget` (MainFrameBudget), and
            // the typing probe's key-press flow hops (`key.flow`). swift-atomics: JobDelegate's inlinable shouldYield
            // names its `Bool: AtomicValue` conformance.
            // CmuxSafeConcurrency: OnceContinuation, the continuation that resumes exactly once (p10-stability-083/088).
            dependencies: ["CmuxNextCompat", "CmuxNextInputCore", "CmuxNextSignposts", "CmuxNextTrace", "CmuxNextMetrics",
                           .product(name: "Atomics", package: "swift-atomics"),
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        // The one test clock of the CmuxNext test targets (ManualClock); test targets only.
        .target(
            name: "CmuxNextWakeupsTestSupport",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWakeupsTests",
            // Trace: the black-box file steps' tests read the ring. Signposts: the frame.tick and present tests (037).
            // Metrics: the key.echo_frame tests (054) and the frame sequences' histograms (057).
            dependencies: ["CmuxNextCompat", "CmuxNextMetrics", "CmuxNextSignposts", "CmuxNextTestSupport", "CmuxNextTrace", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport"],
            swiftSettings: daemonSwiftSettings
        ),
        // Install cmux CLI in PATH: the /usr/local/bin link to the bundled CLI
        // (moved out of CmuxNextApp to keep it under its size cap).
        .target(
            name: "CmuxNextCLIInstall",
            // Wakeups: AsyncProcess runs the administrator prompt's osascript off the caller.
            dependencies: ["CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        // The freeze gate for this process's environment writes (libghostty
        // keeps a copy of environ from ghostty_init). No dependencies.
        .target(
            name: "CmuxNextProcessEnvironment",
            dependencies: ["CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        // Opt-in hang reports from NIGHTLY (plans/cmux-next/hang-reports-DESIGN.md):
        // MetricKit and watchdog inputs, redaction by allow-list, leak scan, upload.
        .target(
            name: "CmuxNextHangReports",
            dependencies: ["CmuxNextCompat", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextWakeups", "CmuxNextInputCore", "CmuxNextFeatures"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextHangReportsTests",
            dependencies: ["CmuxNextCompat", "CmuxNextHangReports", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextInputCore", "CmuxNextInputCoreTestSupport", "CmuxNextWakeups", "CmuxNextFeatures",
                           .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        // Crash and exception reports to Sentry (cx-urd.58): consent, channel
        // environment, release, fingerprint, scrubbing, signal handler order.
        .target(
            name: "CmuxNextCrashReporting",
            dependencies: [
                "CmuxNextCompat",
                // InvariantSink: the process's Invariant reports go to Sentry (p10-stability-099).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                .product(name: "CmuxSentryReporting", package: "CmuxSentryTelemetry"),
                // SentryScrubber: the previous run's blackbox.txt is scrubbed like the event (p09-observability-079).
                .product(name: "CmuxSentryScrubbing", package: "CmuxSentryTelemetry"),
                .product(name: "Sentry-Dynamic", package: "sentry-cocoa"),
                "CmuxNextTrace",
                "CmuxNextWakeups",
                // FeatureFieldState: the launch's features on the Sentry scope (p12-perf-process-151).
                "CmuxNextFeatures",
                // WatchdogHangSinks: the main-thread watchdog's hang sinks, set before Sentry starts (p09-observability-076).
                "CmuxNextControl",
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextCrashReportingTests",
            dependencies: [
                "CmuxNextCrashReporting",
                // ChromiumMinidumpTests: a fake ProcessRunning for the dump symbolizer's atos runs.
                "CmuxNextWakeups",
                // InvariantSinkTests binds the blocking detector's scoped table.
                "CmuxNextCompat",
                // PreviousRunCrashEvidenceTests writes a previous run's black box and crash-key page.
                "CmuxNextTrace",
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                .product(name: "Sentry-Dynamic", package: "sentry-cocoa"),
                // CrashReporterOptionsTests checks the options against CLISentryRuntimePolicy.
                .product(name: "CmuxSentryReporting", package: "CmuxSentryTelemetry"),
                .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
                // SystemCrashReportTests plants a Rust ring and scans the forwarded black box with the hang
                // reports' PrivacyLeakScanner (p09-observability-097).
                "CmuxNextTrace",
                "CmuxNextHangReports",
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // The diff viewer engine (the diff page provider, sidecar, grants,
        // stores and strings). DiffPageService in the App opens and hosts it.
        .target(
            name: "CmuxNextDiff",
            dependencies: [
                "CmuxNextAgentPane",
                "CmuxNextCompat",
                "CmuxNextDaemonService",
                "CmuxNextPages",
                "CmuxNextSettings",
                "CmuxNextWakeups",
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            resources: [.process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        // Design's values without views: tunables, motion tokens, theme specs, settings enums
        // (plans/cmux-next/architecture-refactor-DESIGN.md slice B2). Design re-exports it.
        .target(
            name: "CmuxNextDesignTokens",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextWakeups",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
                "CCmuxAppFFI",
            ],
            swiftSettings: uiSwiftSettings
        ),
        // base::FeatureList: feature declarations and the resolved snapshot (policy, env, local,
        // remote, trial, default), read off the main actor as one array load.
        .target(
            name: "CmuxNextFeatures",
            dependencies: [
                "CmuxNextCompat",
                // BackgroundWork: the remote flags store's file reads and writes (FeatureRemoteStore).
                "CmuxNextWakeups",
                .product(name: "Atomics", package: "swift-atomics"),
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextFeaturesTests",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextFeatures",
                "CmuxNextWakeups",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // The app-daemon wire (plans/cmux-next/chrome-parity/p05-ipc.md section 3.3, task 027):
        // CmuxNextWireGenPlugin runs the host tool CmuxNextWireGen on cmux-tui/spec/sdk-schema.json and
        // resource-operations-v2.json at build time and compiles its output into CmuxNextIPC. The
        // schema files are the command's declared inputs, so only a schema or generator edit reruns
        // it; nothing generated is in git (scripts/ci/generated-files.json, `ipc-wire-swift`).
        .target(
            name: "CmuxNextWireDigest",
            swiftSettings: daemonSwiftSettings
        ),
        .executableTarget(
            name: "CmuxNextWireGen",
            dependencies: ["CmuxNextWireDigest"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWireGenTests",
            dependencies: ["CmuxNextWireGen"],
            swiftSettings: daemonSwiftSettings
        ),
        .plugin(
            name: "CmuxNextWireGenPlugin",
            capability: .buildTool(),
            dependencies: ["CmuxNextWireGen"]
        ),
        .target(
            name: "CmuxNextIPC",
            // CmuxNextCompat: the Mutex of FrameWriter's priority FIFOs (p05-ipc-055)
            // and of StreamDemux's sinks (p05-ipc-056).
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextWireDigest", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings,
            plugins: [.plugin(name: "CmuxNextWireGenPlugin")]
        ),
        .testTarget(
            name: "CmuxNextIPCTests",
            dependencies: [
                // FrameWriterTests' recording sink keeps its bytes in a Mutex.
                "CmuxNextCompat",
                "CmuxNextIPC",
                "CmuxNextWireDigest",
                // MethodTableTests counts allocations through a malloc_logger hook.
                .product(name: "Atomics", package: "swift-atomics"),
                // FrameFuzzTests runs on FuzzRun (seeded replay, long mode).
                .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
                // The fixture schema's generated DaemonWireEvent, which WireEventSetTests decodes with.
                "CmuxNextIPCTestSupport",
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The fixture schema's DaemonWireEvent, built by CmuxNextWireGenPlugin, and its payload types;
        // test targets only. A regular target, not the test target, applies the plugin: a test
        // product links every executable its test targets reach, so a plugin on a test target pulled
        // the host-built CmuxNextWireGen objects into the cross-compiled test link (ld64.lld:
        // unhandled file type). Main-actor default, as the test target, so the emitted enum's
        // `nonisolated` stays checked.
        .target(
            name: "CmuxNextIPCTestSupport",
            dependencies: ["CmuxNextIPC"],
            swiftSettings: uiSwiftSettings,
            plugins: [.plugin(name: "CmuxNextWireGenPlugin")]
        ),
        // Input latency core (plans/cmux-next/chrome-parity/p04-input.md, section 3 (I)): Chromium's
        // EventMetrics for cmux: event kinds, stages, the lock-free open-slot table any thread
        // stamps, the closed-slot ring and the histogram buckets. Pure: no AppKit.
        .target(
            name: "CmuxNextInputCore",
            dependencies: [
                "CmuxNextCompat",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // The one test InputObserving of the CmuxNext test targets (FakeInputTap); test targets only.
        .target(
            name: "CmuxNextInputCoreTestSupport",
            dependencies: ["CmuxNextInputCore"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextInputCoreTests",
            dependencies: ["CmuxNextCompat", "CmuxNextInputCore", "CmuxNextInputCoreTestSupport"],
            swiftSettings: daemonSwiftSettings
        ),
        // The refactor oracle's facet providers and snapshot capture (p15-oracle.md section 3A): the
        // App builds the one provider list (OracleHost) and Control serves it as debug.oracle.snapshot in
        // DEV and bench builds. Pure values: no AppKit, no control socket, so headless services can too.
        // Every source is under DEBUG || CMUX_BENCH_HOOKS (p15-oracle.md section 4 rule 3): Release builds it empty.
        // CmuxNextCompat: the ax facet reads the string tables with the checked file calls.
        .target(
            name: "CmuxNextOracle",
            dependencies: ["CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextOracleTests",
            dependencies: ["CmuxNextOracle", "CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        // The app's one input tap (p04-input.md section 3 (A)): typed subscriptions by event class,
        // phase and window that replace AppKit event monitors and the application object's closures.
        // The only target besides the App that sees NSEvent for input routing; core and service
        // packages take its InputObserving face from CmuxNextInputCore. It depends on nothing above the
        // core, so every ui package (CmuxNextDesign's popups, overlays, tooltips and hover cards too)
        // subscribes to it instead of installing AppKit event monitors. Wakeups (core): its
        // PointerFrameConsumer.post(NSEvent) feeds the window's FrameInputCoalescer.
        .target(
            name: "CmuxNextInput",
            // CmuxNextCompat: MemoryPressureEvents for IntentPrewarmService (p04-input-043).
            // CmuxNextSignposts: InputLatencyTracker's input.latency events and the key.frame and key.scroll_frame
            // intervals its slots carry (p04-input-004, 005).
            dependencies: ["CmuxNextCompat", "CmuxNextInputCore", "CmuxNextSignposts", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // The debug.input control method and its JSON (Control and Settings, which sit above the tap's
        // consumers: CmuxNextSettings depends on CmuxNextDesign, which subscribes to the tap).
        .target(
            name: "CmuxNextInputDiagnostics",
            // Wakeups: the input-turn hop recorder (MainJobGateDiagnostics) answers action `hops`. Compat: the
            // dirty-view recorder's run-loop observers and stack resolver (action `dirty`).
            dependencies: ["CmuxNextCompat", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextControl", "CmuxNextSettings",
                           "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextInputTests",
            dependencies: ["CmuxNextCompat", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextInputDiagnostics",
                           "CmuxNextControl", "CmuxNextSettings", "CmuxNextSignposts", "CmuxNextTrace", "CmuxNextWakeups",
                           "CmuxNextWakeupsTestSupport", "CmuxNextTestSupport", .product(name: "Atomics", package: "swift-atomics")],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextDesign",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDesignTokens",
                // The shared overflow button's ⋮ glyph (OverflowButton, action.more.vertical).
                "CmuxNextIcons",
                "CmuxNextWakeups",
                // The app's one input tap: popups, overlays, tooltips and hover cards subscribe to it
                // (p04-input-013), no AppKit event monitor.
                "CmuxNextInput",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
                // cmux-motion's curves and color mix for ColorTransition (cx-3rf4z).
                "CCmuxAppFFI",
                "CmuxNextTrace",
                "CmuxNextMetrics",
                "CmuxNextSignposts",
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                // LoopHost, the loop seam LoopVisibility conforms to and the Shared views take (p14-energy-056).
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
            ],
            resources: [.process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        // Theme derivation (Ghostty colors -> chrome tokens), contrast, live reload.
        .testTarget(
            name: "CmuxNextDesignTests",
            dependencies: [
                // LoopHost (LoopVisibilityTests).
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                "CmuxNextCompat",
                "CmuxNextDesign",
                "CmuxNextDesignTokens",
                "CmuxNextInput",
                "CmuxNextTestSupport",
                "CmuxNextWakeupsTestSupport",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                "CmuxNextTrace",
                "CmuxNextMetrics",
                // SwitchFrameTimerTests: the switch.* trace names.
                "CmuxNextSignposts",
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextActions",
            // Wakeups: the main-thread task board, where an action run is published as a span so the
            // watchdog samples a run past its 10 ms budget (ActionBudgetMonitor).
            dependencies: ["CmuxNextCompat", "CmuxNextSignposts", "CmuxNextWakeups", "CmuxNextTrace", "CmuxNextMetrics"],
            resources: [
                .process("AccountsActions.xcstrings"),
                .process("ActionCatalog.xcstrings"),
                .process("AgentConfigurationActions.xcstrings"),
                .process("AppStoreActions.xcstrings"),
                .process("BookmarkActions.xcstrings"),
                .process("BrowserProfileActions.xcstrings"),
                .process("BrowserToolbarActions.xcstrings"),
                .process("DevToolsActions.xcstrings"),
                .process("Extensions.xcstrings"),
                .process("HibernationActions.xcstrings"),
                .process("HistoryActions.xcstrings"),
                .process("HangReportsActions.xcstrings"),
                .process("ImportActions.xcstrings"),
                .process("MusicActions.xcstrings"),
                .process("LayoutActions.xcstrings"),
                .process("NewTabActions.xcstrings"),
                .process("Localizable.xcstrings"),
                .process("PageInfoActions.xcstrings"),
                .process("PhoneActions.xcstrings"),
                .process("ProfileActions.xcstrings"),
                .process("RemoteActions.xcstrings"),
                .process("ScreenActions.xcstrings"),
                .process("ServerActions.xcstrings"),
                .process("SettingsActions.xcstrings"),
                .process("SidebarSectionActions.xcstrings"),
                .process("StashActions.xcstrings"),
                .process("ShortcutRecorder.xcstrings"),
                .process("ThemeActions.xcstrings"),
                .process("WorkspaceActions.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextDaemon",
            // CmuxNextIPC: the generated `cmux.protocol/2` requests ResourceOperationClient sends (p05-ipc-045).
            // CmuxSafeConcurrency: OnceContinuation, the continuation that resumes exactly once (p10-stability-087).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts",
                           "CmuxNextIPC", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextDaemonTests",
            // CmuxNextCompat: the tests import it directly (Mutex); undeclared, an incremental build kept a
            // test object compiled against its older interface (an undefined Mutex.withLock symbol at link).
            // CmuxNextWakeups: StoreWaitersTests drive the store's deadline queue on a timer of their own.
            // CmuxNextWakeupsTestSupport: ManualClock, the one test clock (the keyed browser-tab create's waits).
            // CmuxNextIPC: ResourceRequestLineParityTests compares its generated v2 request lines with
            // the hand-built ResourceRequestEnvelope bytes they replace (p05-ipc-024, 045).
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextWakeups",
                           "CmuxNextWakeupsTestSupport", "CmuxNextIPC", "CmuxNextSignposts",
                           .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        // Links libghostty (GhosttyNextKit, whose macOS archive has the lib
        // prefix, so SwiftPM test bundles link it too).
        .target(
            name: "CmuxNextTerminal",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextWakeups",
                "CmuxNextInputCore",
                // The terminals' one modifier watch subscribes to the app's input tap (p04-input-019).
                "CmuxNextInput",
                "CmuxNextProcessEnvironment",
                "CmuxNextDesign",
                "CmuxNextIcons",
                "CmuxNextTerminalGeometry",
                "CmuxNextCopyMode",
                "CmuxNextTerminalFind",
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
                "CmuxNextTrace",
                "CmuxNextMetrics",
                "CmuxNextSignposts",
                // The bounded Kitty image budget the runtime starts with (SubsystemBudget, p07-memory-083).
                "CmuxNextMemory",
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings + ghosttyNextKitCapabilities
        ),
        // Terminal tests that need only TerminalSession (the TextBox composer), without the
        // whole App build. libghostty needs libc++, as in CmuxNextAppTests.
        .testTarget(
            name: "CmuxNextTerminalTests",
            // Compat for Mutex and GhosttyKit for ghostty_surface_t (TerminalOutputLaneHangScopeTests); Wakeups for
            // the typing probe a lane marks (TerminalOutputLaneKeyFlowTests); CmuxFuzzSupport for the link and
            // Ghostty action fuzz suites (p10-stability-030); WakeupsTestSupport for the pointer coalescer's manual clock
            // (TerminalPointerCoalescingTests); Design for the scroller's shared clip (TerminalScrollerTests).
            dependencies: ["CmuxNextCompat", "CmuxNextTerminal", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextInputCore", "CmuxNextWakeups", "CmuxNextInput",
                           "CmuxNextWakeupsTestSupport", "CmuxNextSignposts", "CmuxNextDesign",
                           .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"), .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            // The pin's capabilities: GhosttyTraceHookTests calls the hook through libghostty's record type.
            swiftSettings: uiSwiftSettings + ghosttyNextKitCapabilities,
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // Pure grid-geometry policy for terminal surfaces (which grid a
        // mirror renders, which grid it reports). No GhosttyKit, so it has
        // tests; CmuxNextTerminal applies it to the live surface.
        .target(
            name: "CmuxNextTerminalGeometry",
            swiftSettings: uiSwiftSettings
        ),
        // The terminal find bar's state and search flow (count, next/previous,
        // reveal, close). No GhosttyKit, so it has tests; CmuxNextTerminal
        // wires it to Ghostty's search bindings and draws the bar. No default
        // main-actor isolation: its value types are test arguments, which
        // Swift Testing builds off the main actor.
        .target(
            name: "CmuxNextTerminalFind",
            swiftSettings: daemonSwiftSettings
        ),
        // Copy mode's vim key table and cursor-box geometry. No GhosttyKit;
        // CmuxNextTerminal drives Ghostty's keyboard-copy API.
        .target(
            name: "CmuxNextCopyMode",
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextTabs",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextResources", "CmuxNextIcons", "CmuxNextInput",
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                // OnceContinuation (p10-stability-089).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSidebar",
            // CmuxNextInput: the list hears the app's left presses and releases through the input tap (p04-input-019).
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextResources", "CmuxNextIcons", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CCmuxAppFFI", "CmuxNextTrace", "CmuxNextSignposts", "CmuxNextInput", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Resources"),
            ],
            // The pinned FFI has the sidebar document mirror (cmux_sidebar_mirror_*, sidebar-doc-v1).
            swiftSettings: uiSwiftSettings + [.define("CMUX_SIDEBAR_MIRROR_FFI")]
        ),
        .target(
            name: "CmuxNextPalette",
            // CmuxNextInput: the results' and the Actions menu's frame-aligned hover (PointerFrameHover, p04-input-037).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextActions", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CCmuxAppFFI", "CmuxNextTrace", "CmuxNextSignposts", "CmuxNextWakeups", "CmuxNextInput"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPaletteTests",
            // CmuxTheme: PaletteScopeChipContrastTests derives theme tokens. Compat, Signposts and Trace:
            // PaletteOpenSignpostTests reads the `stall.palette_open` records of a test trace runtime. Wakeups and its
            // test support: the per-frame hover tests' FrameInputTestRig.
            dependencies: ["CmuxNextPalette", "CmuxNextCompat", "CmuxNextSignposts", "CmuxNextTrace",
                           .product(name: "CmuxTheme", package: "CmuxTheme"), "CmuxNextWakeups", "CmuxNextWakeupsTestSupport",
                           "CmuxNextTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextLayout",
            // CmuxNextInput: the root's scroll, magnify and button routing is an intercept on the app's input tap (p04-input-019).
            // CmuxNextInputCore: the strip pan's InputResampler (p04-input-041).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextTrace", "CmuxNextSignposts", "CmuxNextInput",
                           "CmuxNextInputCore"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Pane hosts and render-server motion without the App (plans/cmux-next/rendering-DESIGN.md R2).
        // RemoteLayer: RenderMotionSpikeTests clips a CALayerHost.
        .testTarget(
            name: "CmuxNextLayoutTests",
            // Input, WakeupsTestSupport: LayoutPointerCoalescingTests' hover window and fake-link coalescers.
            dependencies: ["CmuxNextDesign", "CmuxNextInput", "CmuxNextLayout", "CmuxNextRemoteLayer", "CmuxNextWakeups",
                           "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // Browser tab hibernation policy (Memory Saver): which hidden pages freeze or are
        // discarded and when, from facts the App's BrowserHibernation coordinator feeds it
        // (plans/cmux-next/tab-lifecycle.md). Pure values; no engine, no I/O.
        .target(
            name: "CmuxNextHibernation",
            // Wakeups: the one-shot deadline of ContentDiscardScheduler (DemandTimer).
            dependencies: ["CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextHibernationTests",
            dependencies: ["CmuxNextHibernation", "CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // The browser's engine-neutral half: tab and engine values, intents, capability protocols, omnibox
        // and page-info models; no views, no engine (plans/cmux-next/architecture-refactor-DESIGN.md
        // section 8). CmuxNextBrowser depends on it and re-exports it.
        .target(
            name: "CmuxNextBrowserCore",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089); SitePermissionRequest awaits the prompt bar's answer (withOnceContinuation).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextTrace", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextBrowser",
            // SharedRegionC: the Chromium host control channel's sealed shm regions (ChromiumHostSharedRegion).
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-083/088).
            dependencies: ["CmuxNextBrowserCore", "CmuxNextCompat", "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextRemoteFetch", "CmuxNextRemoteLayer", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts", "CmuxNextSharedRegionC",
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            // The CEF shim's C header: its SHA-256 is the shim ABI identity
            // (CEFShimABI, scripts/cmux-next/build-cef-shim.sh).
            resources: [.copy("CEF/Shim/cmux_cef_shim.h"), .process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        // Favicon state owned by the browser chrome. The App supplies the loader and keeps
        // its AppServices extensions in CmuxNextApp; this leaf is also consumable by the
        // read-only UI host without pulling in the app composition root.
        .target(
            name: "CmuxNextFavicons",
            dependencies: ["CmuxNextBrowser", "CmuxNextCompat", "CmuxNextTabs"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserTests",
            // Signposts: CEFTabSwitchShowTests' switch.tab interval.
            dependencies: ["CmuxNextBrowser", "CmuxNextCompat", "CmuxNextDesign", "CmuxNextFavicons", "CmuxNextInput", "CmuxNextInputCore", "CmuxNextRemoteFetch", "CmuxNextRemoteLayer", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts",
                           "CmuxNextTestSupport",
                           // CmuxSafeConcurrency: OnceContinuation (CEFPasswordTests, as PasswordRevealBox takes it).
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        // The WebKit driver for the Rust browser host (plans/cmux-next/browser-host.md).
        .target(
            name: "CmuxNextBrowserAutomation",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-083/088).
            dependencies: ["CmuxNextCompat", "CmuxNextBrowser", "CmuxNextWakeups", "CmuxNextTrace", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserAutomationTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextBrowserAutomation", "CmuxNextDesign", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // The app's provider bridge to the browser host (plans/cmux-next/browser-host.md, step c3).
        .target(
            name: "CmuxNextBrowserHost",
            dependencies: ["CmuxNextCompat", "CmuxNextBrowser", "CmuxNextBrowserAutomation", "CmuxNextWakeups", "CmuxNextTrace"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserHostTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextBrowserAutomation", "CmuxNextBrowserHost", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport", "CmuxNextTrace", "CmuxNextMetrics"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextRemoteLocalhost",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-087).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [.process("Resources")],
            swiftSettings: daemonSwiftSettings
        ),
        // Browser tabs' remote localhost (routes, the proxy's daemon tunnels,
        // badges) and Set Workspace Localhost. The App gives it its machines
        // (RemoteLocalhostMachines) and the approval sheet.
        .target(
            name: "CmuxNextRemoteLocalhostService",
            dependencies: [
                "CmuxNextActions", "CmuxNextBrowser", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService",
                "CmuxNextRemoteLocalhost", "CmuxNextSettings", "CmuxNextWakeups",
            ],
            resources: [.process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSettings",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-089).
            // DesignTokens: the value types Settings parses and writes; Design only for what has not
            // moved yet (DesignSettings, toasts, backdrops; MQ-settings-design, p15-oracle-231).
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextDesignTokens", "CmuxNextActions", "CmuxNextWakeups", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSettingsTests",
            // Compat for the blocking detector (ConfigFileWatcherNoWaitTests).
            dependencies: ["CmuxNextCompat", "CmuxNextSettings", "CmuxNextDesign", "CmuxNextDesignTokens", "CmuxNextActions", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport",
                           .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextSettingsWindow",
            // CmuxSafeConcurrency: ChatRootPicker's OnceContinuation (moved from CmuxNextSettings, p15-oracle-133).
            dependencies: ["CmuxNextSettings", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextActions", "CmuxNextWakeups",
                           .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextControl",
            // CmuxSafeConcurrency: OnceContinuation (p10-stability-087).
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextProcessEnvironment", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts", "CmuxNextInputCore", "CmuxNextOracle", "CmuxNextFeatures", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextControlTests",
            // Signposts: BurstTraceRingTests reads the burst.event catalog name and the burst category bit.
            dependencies: ["CmuxNextWakeups", "CmuxNextWakeupsTestSupport", "CmuxNextCompat", "CmuxNextControl", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextSignposts", "CmuxNextInputCore", "CmuxNextInputCoreTestSupport", "CmuxNextOracle", "CmuxNextFeatures", "CmuxNextTestSupport", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: daemonSwiftSettings
        ),
        // Settings and palette agent CLI updates (moved out of CmuxNextApp/AgentHarnesses):
        // the shared registry handler, owner routes, intents and terminal outcomes.
        .target(
            name: "CmuxNextAgentUpdates",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextPages", "CmuxNextSettings",
                           "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Test-only: every exit() of the test process prints its stack (TestProcessExitTests).
        .target(
            name: "CmuxNextTestExitTrace",
            path: "Tests/Support/CmuxNextTestExitTrace"
        ),
        // Test-only: the in-process benches' cmux-perf-result/v1 writer (PerfResultWriter, read when
        // CMUX_PERF_RESULT_DIR is set; scripts/perf-lab/stories/swift_benches.py, p12-perf-process-217).
        // Foundation only, so the Linux tier's bench targets keep building.
        .target(
            name: "CmuxNextTestSupport",
            path: "Tests/CmuxNextTestSupport",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppTests",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxNextActions",
                "CmuxNextAgentCursor",
                "CmuxNextAgentLanes",
                "CmuxNextAgentUpdates",
                "CmuxNextApp",
                "CmuxNextApps",
                "CmuxNextBookmarks",
                "CmuxNextBrowserCore",
                "CmuxNextBrowserHistory",
                "CmuxNextBrowserImport",
                "CmuxNextBrowserTabs",
                "CmuxNextChiefPetWiring",
                "CmuxNextChiefViews",
                "CmuxNextChromiumRuntime",
                "CmuxNextChromiumWarmup",
                "CmuxNextCompat",
                "CmuxNextComputerUse",
                "CmuxNextCookieImport",
                "CmuxNextCopyMode",
                "CmuxNextCrashReporting",
                "CmuxNextDaemon",
                "CmuxNextDaemonRecovery",
                "CmuxNextDaemonService",
                "CmuxNextDesign",
                "CmuxNextDictation",
                "CmuxNextDiff",
                "CmuxNextEnergy",
                "CmuxNextFeatures",
                "CmuxNextFeed",
                "CmuxNextFileGrid",
                "CmuxNextFiles",
                "CmuxNextFilesUI",
                "CmuxNextFloating",
                "CmuxNextFocus",
                "CmuxNextFocusUI",
                "CmuxNextHangReports",
                "CmuxNextHibernation",
                "CmuxNextHistory",
                "CmuxNextHome",
                "CmuxNextHomeEngine",
                "CmuxNextHostedChief",
                "CmuxNextIPC",
                "CmuxNextImportCards",
                "CmuxNextImportSuggestions",
                "CmuxNextInput",
                "CmuxNextInputCore",
                "CmuxNextInputCoreTestSupport",
                "CmuxNextInputModel",
                "CmuxNextKeepAwake",
                "CmuxNextLaunch",
                "CmuxNextLayout",
                "CmuxNextMacScreen",
                "CmuxNextMemory",
                "CmuxNextMetrics",
                "CmuxNextNowPlaying",
                "CmuxNextOracle",
                // InternalPageDiscardTests shows a page in a fake Chromium host.
                "CmuxNextPagesTestSupport",
                "CmuxNextPalette",
                "CmuxNextProcessEnvironment",
                "CmuxNextRemote",
                "CmuxNextRemoteLocalhostService",
                "CmuxNextRemoteViewSessions",
                "CmuxNextScreenshots",
                "CmuxNextServerHelper",
                "CmuxNextSettings",
                "CmuxNextSignposts",
                "CmuxNextStash",
                "CmuxNextTabs",
                "CmuxNextTasks",
                "CmuxNextTerminalGeometry",
                "CmuxNextTestExitTrace",
                "CmuxNextTestSupport",
                "CmuxNextTrace",
                "CmuxNextVSCodeServer",
                "CmuxNextWakeups",
                "CmuxNextWakeupsTestSupport",
                "CmuxNextWebUpdates",
                "CmuxNextWorkspaceNaming",
                // UnmountedWorkspaceLeavesNoObjectsTests and the rule-9 sweep cases read the repair's counts.
                "CmuxNextWorkspaceRepair",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                // DiffTurnPatchFuzzTests (p10-stability-030).
                .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
                // GhosttyGlassMinimumContrastTests builds a Ghostty config.
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                // MacInstallTeamAuthTests signs team challenges with the install key.
                .product(name: "CmuxInstallAuthCore", package: "CmuxInstallAuthCore"),
                // AgentActivityOneShotCancelTests records the oneShot continuation's faults (p10-stability-171).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                // UpdateLoadingIndicatorTests feeds Sparkle's update states.
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
                .product(name: "CmuxVNC", package: "CmuxVNC"),
                // ReduceMotionLoopTests builds the vendored Home typing indicators.
                .product(name: "MessagesLabHome", package: "CmuxMessagesLab"),
                .product(name: "MessagesLabSidebar", package: "CmuxMessagesLab"),
            ],
            swiftSettings: uiSwiftSettings,
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // Phone access (plans/cmux-next/cloud-ios.md): irx host, the daemon
        // lane splice, and the mobile.* compat adapter for shipped iOS builds.
        // No UI; the App wires it to the daemon connection and auth.
        .target(
            name: "CmuxNextMobile",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDaemon",
                "CmuxNextWakeups",
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxIrxTransport", package: "CmuxIrxTransport"),
                // OnceContinuation (p10-stability-087).
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                "CmuxNextTrace",
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // The cmux iPhone host (Settings > Mobile): follows the account and
        // mobile.allowIPhoneConnections, runs the bundled cmux-mobile-host through
        // CmuxNextMobile's MobileHostSupervisor, lists and removes the account's
        // phones, and projects the Settings page's card.
        .target(
            name: "CmuxNextMobileHost",
            dependencies: [
                "CmuxNextAgentPane", "CmuxNextCloud", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService",
                "CmuxNextDesign", "CmuxNextMobile", "CmuxNextPages", "CmuxNextRemoteBrowser", "CmuxNextSettings",
                "CmuxNextWakeups",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextMobileHostTests",
            dependencies: ["CmuxNextMobileHost", "CmuxNextMobile", "CmuxNextAgentPane", "CmuxNextPages", "CmuxNextSettings", "CmuxNextWakeups",
                           "CmuxNextCompat", "CmuxNextDaemon", .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                           .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextMobileTests",
            dependencies: [
                "CmuxNextMobile",
                "CmuxNextDaemon",
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxMobileRPC", package: "CmuxMobileRPC"),
                .product(name: "CmuxMobileSSH", package: "CmuxMobileSSH"),
                "CmuxNextTrace",
                "CmuxNextMetrics",
                "CmuxNextWakeups",
                "CmuxNextWakeupsTestSupport",
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextActionsTests",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextTrace", "CmuxNextMetrics", "CmuxNextWakeups", "CmuxNextTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
    ] + [appFFI]

/// Linux SwiftPM copies an `.xcstrings` catalog into the bundle as JSON that Foundation cannot read.
/// In the Linux mode (`CMUX_SWIFTPM_TARGET_LINUX=1`, plans/cmux-next/chrome-parity/p15-oracle.md H),
/// a target with a catalog takes the tables scripts/cmux-next/linux/compile-xcstrings.py compiled
/// from it, linked into its folder as `LinuxStringTables/<lang>.lproj/<table>.strings`; without
/// them the build stops on that missing folder. macOS compiles the catalogs itself.
func addLinuxStringTables(to targets: [Target]) {
#if os(Linux)
    let files = FileManager.default
    for target in targets {
        let parent: String
        switch target.type {
        case .regular, .executable: parent = "Sources"
        case .test: parent = "Tests"
        default: continue
        }
        let folder = Context.packageDirectory + "/" + (target.path ?? parent + "/" + target.name)
        let hasCatalog = files.enumerator(atPath: folder)?.contains { ($0 as? String)?.hasSuffix(".xcstrings") == true }
        if hasCatalog == true {
            target.resources = (target.resources ?? []) + [.process("LinuxStringTables")]
        }
    }
#endif
}

if Context.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    addLinuxStringTables(to: packageTargets)
}

let package = Package(
    name: "CmuxNext",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: packageProducts,
    dependencies: [
        .package(path: "../../Shared/CmuxGhosttyKit"),
        .package(path: "../../Shared/CMUXAuthCore"),
        .package(path: "../../Shared/CmuxInstallAuthCore"),
        .package(path: "../../Shared/CmuxAuthRuntime"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTheme"),
        // App Attest and DeviceCheck: the free tier's device proof (cx-ds09i).
        .package(path: "../../Shared/CmuxAppAttest"),
        .package(path: "../../Shared/CmuxAgentBrands"),
        // Vendored from manaflow-ai/cmux-cua at CMUX_CUA_PINNED_SHA (scripts/cmux_agent_cursor_vendor.py).
        .package(path: "../../Shared/CmuxAgentCursor"),
        .package(path: "../../Shared/CmuxHomeCore"),
        .package(path: "../../Shared/CmuxFeedPushCore"),
        .package(path: "../../Shared/CmuxHomeRender"),
        // Agent questions: one harness-neutral model (plans/cmux-next/agent-questions.md).
        .package(path: "../../Shared/CmuxAgentQuestion"),
        // The Mac Home transcript: MessagesLabAppKitNative, vendored (home-mac.md).
        .package(path: "../../Shared/CmuxMessagesLab"),
        .package(path: "../../Shared/CmuxIrxTransport"),
        // Seeded property tests (test targets only): p10-stability-016.
        .package(path: "../../Shared/CmuxFuzzSupport"),
        // The portable Mutex (os_unfair_lock) every package of the closure shares: p10-stability-172.
        .package(path: "../../Shared/CmuxSafeConcurrency"),
        // The threading leaf of the Shared/iOS packages; Compat installs its blockingCall hook: p02-threads-130.
        .package(path: "../../Shared/CmuxThreading"),
        // RFB (VNC) client for compatibility hosts in the remote view pane (remote-desktop.md 12).
        .package(path: "../../Shared/CmuxVNC"),
        .package(path: "../../Shared/CmuxScreenKit"),
        // Crash reports: the shared scrubber and the Sentry SDK at the same cap as the shared package.
        // The dynamic SDK (Sentry-Dynamic): see CmuxSentryTelemetry's Package.swift (personality routines).
        .package(path: "../../Shared/CmuxSentryTelemetry"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", "9.3.0"..<"9.29.0"),
        // Sparkle driver shared with the legacy app (no bonsplit, no legacy deps).
        .package(path: "../CmuxUpdater"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        // Lock-free atomics on macOS 14 for CmuxNextCompat.Atomic (already resolved through
        // other dependencies; Apache-2.0).
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        // Test-only: the shipped iOS app's own RPC decoders verify the compat adapter.
        .package(path: "../../iOS/CmuxMobileRPC"),
        // Test-only: the iOS app's cmux-tui client drives the daemon lane end to end.
        .package(path: "../../iOS/CmuxMobileSSH"),
    ],
    targets: packageTargets,
)

#if os(Linux)
// The Linux mode (plans/cmux-next/chrome-parity/p15-oracle.md section H): only the Linux tier scripts
// (scripts/cmux-next/linux/) set CMUX_SWIFTPM_TARGET_LINUX. A build for an Apple platform, here or on a
// Linux host, never sets it, so the Apple manifest above, its dump-package and Package.resolved are the
// same with or without this block. The mode keeps the tier's targets and only the packages they use.
// The tier is a literal in this file, never a file read: SwiftPM's manifest cache is keyed on this text.
import Foundation

if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    /// The Linux tier as scripts/cmux-next/linux/linux-tier.py renders it from linux-tier.json.
    struct LinuxTier {
        struct FFI {
            let replaces: String
            let target: String
            let library: String
            let libraryDirectory: String
        }

        struct Generated {
            let targets: [String]
            let testTargets: [String]
            let products: [String]
            let pathDependencies: [String]
            let remoteDependencies: [String]
            let linuxDependencies: [String: [String]]
        }

        let ffi: FFI
        let generated: Generated

        var zlibTarget: String { "CZlib" }
        var cryptoPackage: String { "swift-crypto" }

        /// SwiftPM's identity of a package location: its last path component without `.git`, lowercased.
        func identity(_ location: String) -> String {
            let last = location.split(separator: "/").last.map(String.init) ?? location
            return (last.hasSuffix(".git") ? String(last.dropLast(4)) : last).lowercased()
        }

        /// The Linux-only targets the tier lists: the FFI module map in place of the xcframework, and zlib.
        func linuxTargets(packageDirectory: String) -> [Target] {
            var targets: [Target] = []
            if generated.targets.contains(ffi.target) {
                targets.append(Target.target(
                    name: ffi.target,
                    path: "Sources/" + ffi.target,
                    publicHeadersPath: ".",
                    linkerSettings: [
                        .unsafeFlags(["-L", packageDirectory + "/" + ffi.libraryDirectory]),
                        .linkedLibrary(ffi.library),
                    ]
                ))
            }
            if generated.targets.contains(zlibTarget) {
                targets.append(Target.systemLibrary(name: zlibTarget, path: "Sources/" + zlibTarget))
            }
            return targets
        }

        /// A dependency as the Linux mode keeps it: the FFI target in place of the xcframework, nil for a
        /// target outside the tier or a product of a package the tier does not use.
        func linuxDependency(_ dependency: Target.Dependency, kept: Set<String>, packages: Set<String>) -> Target.Dependency? {
            switch dependency {
            case .targetItem(let name, let condition), .byNameItem(let name, let condition):
                if name == ffi.replaces {
                    return kept.contains(ffi.target) ? .target(name: ffi.target, condition: condition) : nil
                }
                return kept.contains(name) ? dependency : nil
            case .productItem(_, let package, _, _):
                return packages.contains(identity(package ?? "")) ? dependency : nil
            @unknown default:
                return dependency
            }
        }

        /// The stand-ins a target's imports need on Linux (linux-tier.py reads them from its sources).
        func standIns(of target: String) -> [Target.Dependency] {
            (generated.linuxDependencies[target] ?? []).map { name in
                name == zlibTarget ? .target(name: name) : .product(name: name, package: cryptoPackage)
            }
        }

        func apply(to package: Package, crypto: Package.Dependency, packageDirectory: String) {
            let kept = Set(generated.targets + generated.testTargets)
            let packages = Set(generated.pathDependencies.map(identity) + generated.remoteDependencies)
            var targets = package.targets.filter { kept.contains($0.name) }
            for target in targets {
                target.dependencies = target.dependencies.compactMap {
                    linuxDependency($0, kept: kept, packages: packages)
                } + standIns(of: target.name)
            }
            targets += linuxTargets(packageDirectory: packageDirectory)
            package.targets = targets
            package.products = package.products.filter { generated.products.contains($0.name) }
            package.dependencies = package.dependencies.filter { dependency in
                switch dependency.kind {
                case .fileSystem(_, let path): packages.contains(identity(path))
                case .sourceControl(_, let location, _): packages.contains(identity(location))
                default: false
                }
            }
            if generated.remoteDependencies.contains(cryptoPackage) {
                package.dependencies.append(crypto)
            }
        }
    }

    // BEGIN linux-tier.py: generated from linux-tier.json by scripts/cmux-next/linux/linux-tier.py; do not edit.
    let linuxTier = LinuxTier(
        ffi: LinuxTier.FFI(
            replaces: "CCmuxAppFFI",
            target: "CCmuxAppFFILinux",
            library: "cmux_app_ffi",
            libraryDirectory: ".build-linux/ffi/lib",
        ),
        generated: LinuxTier.Generated(
            targets: [
                "CmuxNextCompat",
                "CmuxNextTrace",
                "CmuxNextMetrics",
                "CmuxNextFeatures",
                "CmuxNextSignposts",
                "CmuxNextWakeups",
                "CmuxNextWakeupsTestSupport",
                "CmuxNextTestSupport",
                "CmuxNextProcessEnvironment",
                "CCmuxAppFFILinux",
                "CmuxNextActions",
                "CmuxNextDaemon",
                "CmuxNextFocus",
                "CmuxNextTerminalGeometry",
                "CmuxNextCopyMode",
                "CmuxNextTerminalFind",
                "CmuxNextHostPressure",
                "CmuxNextDesignTokens",
                "CmuxNextErrorJournal",
                "CmuxNextHangReports",
                "CmuxNextFiles",
                "CmuxNextBrowserImport",
                "CmuxNextImportSuggestions",
                "CmuxNextChromiumRuntime",
                "CmuxNextDevices",
                "CmuxNextVSCodeServer",
                "CmuxNextRemoteFetch",
                "CmuxNextBrowserCore",
                "CmuxNextBridge",
                "CmuxNextWorkspaceNaming",
                "CmuxNextCloud",
                "CmuxNextCodeRouter",
                "CmuxNextRemote",
                "CmuxNextMobile",
                "CmuxNextSettings",
                "CmuxNextControl",
                "CmuxNextHibernation",
                "CmuxNextWorkspaceRepair",
                "CmuxNextKeepAwake",
                "CmuxNextRemoteLocalhost",
                "CmuxNextServerHelper",
                "CmuxNextCLIInstall",
                "CmuxNextInputModel",
                "CZlib",
            ],
            testTargets: [
                "CmuxNextActionsTests",
                "CmuxNextChromiumRuntimeTests",
                "CmuxNextCodeRouterTests",
                "CmuxNextCompatTests",
                "CmuxNextControlTests",
                "CmuxNextDaemonTests",
                "CmuxNextDevicesTests",
                "CmuxNextErrorJournalTests",
                "CmuxNextFeaturesTests",
                "CmuxNextFilesTests",
                "CmuxNextHangReportsTests",
                "CmuxNextHostPressureTests",
                "CmuxNextImportSuggestionsTests",
                "CmuxNextKeepAwakeTests",
                "CmuxNextMetricsTests",
                "CmuxNextMobileTests",
                "CmuxNextSignpostsTests",
                "CmuxNextTraceTests",
                "CmuxNextVSCodeServerTests",
                "CmuxNextWakeupsTests",
                "CmuxNextWorkspaceRepairTests",
            ],
            products: [],
            pathDependencies: [
                "Packages/Shared/CMUXAuthCore",
                "Packages/Shared/CMUXMobileCore",
                "Packages/Shared/CmuxAgentBrands",
                "Packages/Shared/CmuxAuthRuntime",
                "Packages/Shared/CmuxInstallAuthCore",
                "Packages/Shared/CmuxIrxTransport",
                "Packages/Shared/CmuxSafeConcurrency",
                "Packages/Shared/CmuxTheme",
                "Packages/Shared/CmuxThreading",
                "Packages/iOS/CmuxMobileRPC",
                "Packages/iOS/CmuxMobileSSH",
            ],
            remoteDependencies: ["swift-atomics", "swift-crypto"],
            linuxDependencies: [
                "CmuxNextBrowserCore": ["Crypto"],
                "CmuxNextBrowserImport": ["CZlib"],
                "CmuxNextChromiumRuntime": ["Crypto"],
                "CmuxNextChromiumRuntimeTests": ["Crypto"],
                "CmuxNextCloud": ["Crypto"],
                "CmuxNextCodeRouter": ["Crypto"],
                "CmuxNextDaemon": ["CZlib", "Crypto"],
                "CmuxNextDaemonTests": ["Crypto"],
                "CmuxNextDesignTokens": ["Crypto"],
                "CmuxNextDevices": ["Crypto"],
                "CmuxNextDevicesTests": ["Crypto"],
                "CmuxNextMobile": ["Crypto"],
                "CmuxNextRemote": ["Crypto"],
                "CmuxNextRemoteFetch": ["CZlib"],
                "CmuxNextRemoteLocalhost": ["Crypto"],
                "CmuxNextSettings": ["Crypto"],
            ],
        ),
    )
    // END linux-tier.py

    linuxTier.apply(
        to: package,
        crypto: .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        packageDirectory: Context.packageDirectory
    )
}
#endif
