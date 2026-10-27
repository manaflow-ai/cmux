// swift-tools-version: 6.2

import PackageDescription

// Umbrella package for the cmux-next app (plans/cmux-next/shell.md).
// The Xcode target `cmux-next` compiles only App/main.swift and links the
// `CmuxNextApp` product; every other line of app code lives here, split into
// modules so later agents can work on them in parallel.
//
// Dependency direction (no cycles, no upward imports):
//   CmuxNextApp -> every feature module
//   CmuxNextBridge -> Daemon, Layout, Sidebar, Tabs (App-layer mapping, testable)
//   CmuxNextBrowserCore -> Compat, Wakeups (the browser's engine-neutral values and protocols; Browser re-exports it)
//   CmuxNextFavicons -> CmuxNextBrowser, CmuxNextTabs (public read-only favicon leaf)
//   CmuxNextTabs, Sidebar, Layout, Browser -> CmuxNextDesign; Tabs, Sidebar -> CmuxNextIcons; Palette -> Design, Actions
//   Feature UI modules never import CmuxNextDaemon; the App maps daemon state into their view models.
//   CmuxNextTerminal -> CmuxNextTerminalGeometry, CmuxNextCopyMode (pure), CmuxGhosttyKit (binary)
//   CmuxNextCompat -> swift-atomics, system frameworks (back-ports of newer system APIs for the
//     macOS 14 floor: Mutex, Atomic; any module may import it; plans/cmux-next/macos-floor.md)
//   CmuxNextWakeups -> Compat, Signposts, system frameworks (the only sanctioned wakeup primitives:
//     FrameScheduler, DemandTimer, Backoff, WakeupLedger, and the one main-thread scheduler's
//     per-frame budget MainFrameBudget; plans/cmux-next/idle-wakeups.md, main-thread-budget.md)
//   CmuxNextDesign -> CmuxTheme, CCmuxAppFFI (cmux-motion curves and color mix), Icons (OverflowButton's glyph); CmuxNextActions -> Signposts; CmuxNextDaemon -> Wakeups
//   CmuxNextSignposts -> Compat, system frameworks (always-on os_signpost intervals, the one name catalog, CommitBoundary,
//     the opt-in MetricKit mirror for hang reports)
//   CmuxNextDesignTokens -> Compat, Wakeups, CmuxTheme, CCmuxAppFFI (Design's values without views: tunables,
//     motion tokens, theme specs, settings enums; CmuxNextDesign re-exports it)
//   CmuxNextIcons -> system frameworks only (the cmux icon pack, catalog, renderer and Icon view)
//   CmuxNextChiefMemory -> Design (the built-in Memory Inspector: model and view; the App supplies its daemon-backed source)
//   CmuxNextSettings -> Design, Actions (cmux.json load/watch/apply, SettingsSchema)
//   CmuxNextSettingsWindow -> Settings, Design, Icons, Actions, Wakeups (Debug Settings, SwiftUI; Settings deep links and the string catalog the React Settings page reads)
//   CmuxNextControl -> Actions, Settings, Daemon (app control socket; no UI; Compat/ forwards cmux CLI verbs to cmux-tui)
//   CmuxNextCloud -> CMUXAuthCore, CmuxAuthRuntime (Stack auth, /api/vm REST,
//     WireGuard hub and cmux-tui remote links; no UI, no daemon)
//   CmuxNextRemote -> CmuxNextCloud (SSH machines: ssh argv, probe, install, relay policy; no UI, no daemon)
//   CmuxNextMobile -> Daemon, CMUXMobileCore, CmuxIrxTransport (phone host; no UI)
//   CmuxNextUpdater -> Design, Icons, CmuxUpdater, Sparkle (update checks, appcast probe, update sheet; no daemon)
//   CmuxNextMallocZone -> libSystem only (C: the delegating default malloc zone that lets the
//     Chromium framework load later from another thread; plans/cmux-next/browser-isolation.md)
//   CmuxNextRemoteLayer -> QuartzCore only (ObjC header: CALayerHost, the remote layer a layer-hosted
//     Chromium page draws through; plans/cmux-next/cef-layer-hosting-DESIGN.md)
//   CmuxNextBrowserImport -> system frameworks only (browser detection, parsers, importer; no UI)
//   CmuxNextBrowserHistory -> Browser, Daemon, Compat (a browser tab's saved history across relaunches; no UI)
//   CmuxNextOnboarding -> Design, Icons, BrowserImport (first-run window; the App supplies OnboardingServices)
//   CmuxNextHome -> Compat, Design, Dictation, Wakeups, MessagesLabHome (the Home transcript: MessagesLabAppKitNative's
//     vendored code over the shared HomeStore; no daemon; plans/cmux-next/home-mac.md),
//     MessagesLabSidebar (MessagesLab's conversation list, the v1 sidebar seam)
//   CmuxNextHomeEngine -> AgentPane, Actions, Cloud, Compat, Daemon, Design, Home, Icons, Wakeups,
//     CmuxHomeCore, CmuxAgentQuestion (Home sources, Chief host and migration, Home strings; the App
//     supplies HomeService over AppServices)
//   CmuxNextDaemonService -> Daemon, Actions, AgentPane, Apps, Compat, Control, Layout, Wakeups
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
//   CmuxNextAccounts -> CodeRouter, Design, Icons (Settings > Accounts and the onboarding step; the App supplies AccountsServices)
//   CmuxNextAgentIntegrations -> Daemon, Pages, Settings (Settings > Agents > Agent integrations: relays the bundled
//     CLI's `agent hook status|install|uninstall`; the App supplies the CLI's location)
//   CmuxNextBookmarks -> Design, Icons (bookmark tree per browser profile, Netscape HTML, ranking, file store,
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
//   CmuxNextServer -> Design, Icons (server menubar panel, pairing, approver sheet and health prototypes
//     over a projection of `server.status`; no daemon; the App supplies the source;
//     plans/cmux-next/server.md)
//   CmuxNextRemoteView -> Design, Icons (remote desktop pane: decode, presenters, chrome, input capture;
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
//   CmuxNextServerHelper -> system frameworks only (privileged helper XPC protocol, fix allowlist,
//     same-team listener; plans/cmux-next/server.md 9.4); the App links it for the client side
//   CmuxNextServerHelperDaemon -> ServerHelper (the root helper executable; bundled by
//     scripts/cmux-next/bundle-server-helper.sh, not linked into the App)
//   CmuxNextDictation -> Wakeups (on-device speech: SpeechAnalyzer, SFSpeechRecognizer fallback,
//     the session state machine; no UI)
//   CmuxNextErrorJournal -> system frameworks only (the bounded, deduplicated error journal
//     `cmux errors` reads: app log, page consoles, acpmux and Chief logs, crash reports)
//   CmuxNextFiles -> system frameworks only (Files pane core: listing, FSEvents, file operations,
//     Undo, the pane model; no AppKit; plans/finder-parity/PARITY.md)
//   CmuxNextFilesUI -> Files, Design, Compat (the Files pane's AppKit views: list, icons, columns,
//     path bar, Quick Look, drag in and out)
//   CmuxNextCrashReporting -> CmuxSentryReporting, Sentry (crash and exception reports to Sentry:
//     consent, channel environment, release, scrubbing; no UI, no daemon; cx-urd.58)
//   CmuxNextSessionTransfer -> Design, Settings (Move Sessions from Another cmux Build: the
//     transferable session and peer values, the picker and the toast text; no AppKit, no daemon;
//     the App's SessionTransferService discovers peers and moves sessions; cx-yxmkh)
//   CmuxNextHangReports -> Compat, system frameworks, MetricKit (opt-in hang reports for NIGHTLY:
//     MetricKit and watchdog inputs, allow-list redaction, leak scan, rotating install id, outbox,
//     upload; no UI, no daemon; plans/cmux-next/hang-reports-DESIGN.md)

/// Settings shared by every UI target: Swift 6 mode, main-actor by default.
let uiSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

/// The daemon client is not main-actor by default: one actor owns the socket.
let daemonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

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
    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-619b1a3c815467557791a743a4f4475e9ab20a23/CCmuxAppFFI.xcframework.zip",
    checksum: "b68613ebc46fe2fecb2af826fa3c0e4827a245b2c167493ff5f7bcf93f8f1e60"
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
            name: "CmuxNextCloudCredentials",
            dependencies: ["CmuxNextCloud", "CmuxNextDaemon", "CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextAppCore",
            dependencies: ["CmuxNextActions", "CmuxNextAgentPane", "CmuxNextBridge", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextSidebar"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextApp",
            dependencies: [
                "CmuxNextAppCore",
                "CmuxNextCloudCredentials",
                "CmuxNextChiefMemory",
                "CmuxNextCompat",
                "CmuxNextFavicons",
                "CmuxNextFiles",
                "CmuxNextFilesUI",
                "CmuxNextVSCodeServer",
                "CmuxNextKeepAwake",
                "CmuxNextChromiumWarmup",
                "CmuxNextChromiumRuntime",
                "CmuxNextBrowserTabs",
                "CmuxNextPhoneAccess",
                "CmuxNextPhone",
                "CmuxNextPopups",
                "CmuxNextWorkspaceRepair",
                "CmuxNextCLIInstall",
                "CmuxNextMallocZone",
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
                "CmuxNextChiefPetWiring",
                "CmuxNextHostedChief",
                "CmuxNextDaemonService",
                "CmuxNextAgentUpdates",
                "CmuxNextFocus",
                "CmuxNextFocusUI",
                "CmuxNextComputerUse",
                "CmuxNextAgentQuestion",
                "CmuxNextAgentPermissions",
                "CmuxNextSessionTransfer",
                "CmuxNextDaemonRecovery",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                // The signed approve answer format shared with the iPhone (cx-aocz).
                .product(name: "CmuxFeedPushCore", package: "CmuxFeedPushCore"),
                // The free tier's App Attest provider is composed here (cx-ds09i).
                .product(name: "CmuxAppAttest", package: "CmuxAppAttest"),
                "CmuxNextWakeups",
                "CmuxNextActions",
                "CmuxNextDaemon",
                "CmuxNextDesign",
                "CmuxNextDesignTokens",
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
                "CmuxNextSignposts",
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
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The Chief pet's glue outside the App (code-quality SW14): its rows in the Chief Settings
        // popover (Show Chief Pet, Pet Character) and the notice it makes from a daemon notification.
        .target(
            name: "CmuxNextChiefPetWiring",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextFloating", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextFloatingTests",
            dependencies: ["CmuxNextDesign", "CmuxNextFloating"],
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
            dependencies: ["CmuxNextActions", "CmuxNextAgentPane", "CmuxNextBrowser", "CmuxNextCompat", "CmuxNextSettings", "CmuxNextSidebar", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Stash (a native OneTab, cx-rws36): the Stashed page's source on this Mac's daemon.
        // The App only answers `StashHost`.
        .target(
            name: "CmuxNextStash",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextHistory"],
            swiftSettings: uiSwiftSettings
        ),
        // Agent pane (plans/cmux-next roadmap Phase 1): hosts the React pane
        // from webviews/src/agent-session/acpmux, built into
        // Resources/agent-pane by scripts/cmux-next/build-agent-pane-web.sh,
        // and answers its versioned handshake (find or start acpmux, endpoint,
        // token, session id). Everything above the handshake is TypeScript.
        .target(
            name: "CmuxNextAgentPane",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextErrorJournal", "CmuxNextActions", "CmuxNextDictation", "CmuxNextPages", "CmuxNextRemoteFetch", "CmuxNextSettings", "CmuxNextWakeups",
                           .product(name: "CmuxAppAttest", package: "CmuxAppAttest")],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/agent-pane"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAgentPaneTests",
            dependencies: ["CmuxNextAgentPane", "CmuxNextDaemon", "CmuxNextActions", "CmuxNextCompat", "CmuxNextDesign", "CmuxNextDictation", "CmuxNextPages", "CmuxNextPagesTestSupport", "CmuxNextRemoteFetch", "CmuxNextSettings", "CmuxNextWakeups", "CmuxNextWakeupsTestSupport"],
            swiftSettings: uiSwiftSettings
        ),
        // Dictation (the composer's mic): the on-device speech engines and
        // the session state machine. Engines are actors fed by a real-time
        // audio tap, so the module is not main-actor by default.
        .target(
            name: "CmuxNextDictation",
            dependencies: ["CmuxNextWakeups"],
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
            dependencies: ["CmuxNextCloud", "CmuxNextCodeRouter", "CmuxNextDesign", "CmuxNextIcons", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                           .product(name: "CMUXAuthCore", package: "CMUXAuthCore")],
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
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextBrowser"],
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
            dependencies: ["CmuxNextActions", "CmuxNextBrowser", "CmuxNextBrowserImport", "CmuxNextDesign", "CmuxNextWakeups"],
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
        // The cards' center: the scan schedule, the job runner and the `import.*` actions, for
        // Settings › Import (no Home or New Tab suggestion). The App supplies `ImportCardsHost`.
        .target(
            name: "CmuxNextImportCards",
            dependencies: ["CmuxNextActions", "CmuxNextBrowserImport", "CmuxNextCompat", "CmuxNextDesign",
                           "CmuxNextImportSuggestions", "CmuxNextOnboarding", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextOnboarding",
            dependencies: ["CmuxNextDesign", "CmuxNextIcons", "CmuxNextBrowserImport"],
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
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextWakeups"],
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
        // QuartzCore's CALayerHost, declared for a typed call (layer-hosted Chromium pages).
        .target(name: "CmuxNextRemoteLayer", linkerSettings: [.linkedFramework("QuartzCore")]),
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
            dependencies: [
                "CmuxNextAgentPane", "CmuxNextActions", "CmuxNextCloud", "CmuxNextCompat",
                "CmuxNextDaemon", "CmuxNextDesign", "CmuxNextHome", "CmuxNextIcons", "CmuxNextWakeups",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
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
                "CmuxNextHomeEngine", "CmuxNextDaemon", "CmuxNextDesign",
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
                "CmuxNextDaemon", "CmuxNextLayout", "CmuxNextWakeups",
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
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
            dependencies: ["CmuxNextActions", "CmuxNextDesign", "CmuxNextSignposts"],
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
            dependencies: ["CmuxNextAgentActivity", "CmuxNextCompat", "CmuxNextSettings", "CmuxNextWakeups"],
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
            dependencies: ["CmuxNextDesign", "CmuxNextIcons", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands")],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // DNS-pinned HTTPS fetches for untrusted page-selected resources. Shared by browser
        // favicons, markdown remote images, and Agent reply media without coupling their domains.
        .target(
            name: "CmuxNextRemoteFetch",
            dependencies: ["CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        // React pages (plans/cmux-next/react-pages.md): one WKWebView host, one cmux-page://<id>/
        // origin per page, the cmuxPage bridge and the page router. Pages ship as one self-contained
        // index.html each under Resources/pages (scripts/cmux-next/build-pages-web.sh).
        .target(
            name: "CmuxNextPages",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextErrorJournal", "CmuxNextSettings", "CmuxNextWakeups"],
            resources: [.copy("Resources/pages"), .process("Localizable.xcstrings")],
            swiftSettings: uiSwiftSettings
        ),
        // The one test double of PageChromiumPage / PageChromiumHosting, for every test target
        // that shows a page in Chromium: a protocol change edits one fake, compiled by the
        // protocol's own tests (a private copy in CmuxNextAgentPaneTests broke the test build).
        .target(
            name: "CmuxNextPagesTestSupport",
            dependencies: ["CmuxNextPages", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPagesTests",
            dependencies: ["CmuxNextCompat", "CmuxNextPages", "CmuxNextPagesTestSupport", "CmuxNextSettings", "CmuxNextDesign"],
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
            dependencies: ["CmuxNextDesign", "CmuxNextIcons"],
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
            dependencies: ["CmuxNextDesign", .product(name: "CmuxAgentCursor", package: "CmuxAgentCursor")],
            swiftSettings: uiSwiftSettings
        ),
        // Session transfer (cx-yxmkh): the values another local cmux build
        // hands over, the Move Sessions picker as data and its toast text.
        // Pure; the App discovers peers and moves sessions.
        .target(
            name: "CmuxNextSessionTransfer",
            dependencies: ["CmuxNextDesign", "CmuxNextSettings"],
            resources: [.process("Resources/Localizable.xcstrings")],
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
            dependencies: ["CmuxNextActions", "CmuxNextBridge", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDesignTokens"],
            resources: [.process("Resources/WorkspaceNaming.xcstrings")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWorkspaceNamingTests",
            dependencies: ["CmuxNextWorkspaceNaming", "CmuxNextActions", "CmuxNextBridge", "CmuxNextDaemon", "CmuxNextSidebar"],
            swiftSettings: uiSwiftSettings
        ),
        // Phone tabs (plans/cmux-next/phone.md): simulators through simctl, real
        // iPhones through devicectl, recordings and feedback clips. No daemon,
        // no UI framework beyond AppKit; the App supplies the page and the sink.
        .target(
            name: "CmuxNextPhone",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPhoneTests",
            dependencies: ["CmuxNextPhone", "CmuxNextCompat"],
            resources: [.copy("Fixtures")],
            swiftSettings: daemonSwiftSettings
        ),
        // Files (u2360, plans/finder-parity/PARITY.md): the Finder-parity file browser's core.
        // Off-main getattrlistbulk listing, Finder name order, FSEvents per item, file
        // operations with conflict answers and Undo, and the pane model. No AppKit; the
        // Screenshots pane and the Files pane both read folders through it.
        .target(
            name: "CmuxNextFiles",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextFilesTests",
            dependencies: ["CmuxNextFiles"],
            swiftSettings: daemonSwiftSettings
        ),
        // The Files pane's AppKit views over CmuxNextFiles: list (NSTableView), icons
        // (NSCollectionView), columns (NSBrowser), path bar, Quick Look, drag in and out,
        // the shared icon and thumbnail cache. The App hosts it as an internal page.
        .target(
            name: "CmuxNextFilesUI",
            dependencies: ["CmuxNextFiles", "CmuxNextDesign", "CmuxNextCompat"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Keep awake (sessions.keepAwake): one idle-sleep hold for the Keep Mac Awake
        // action and working local agents, released on battery unless the user
        // chose Always. IOKit's power-source notification, no polling.
        .target(
            name: "CmuxNextKeepAwake",
            dependencies: ["CmuxNextBridge", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextKeepAwakeTests",
            dependencies: ["CmuxNextKeepAwake", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        // Host pressure (cmuxterm-hq#2995): the shared host budget's verdict (acpmux's
        // `host_pressure`, else the same formula locally) as a level that does not flicker.
        // The memory pressure dispatch source, plus one 15 s timer for load and swap.
        .target(
            name: "CmuxNextHostPressure",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextHostPressureTests",
            dependencies: ["CmuxNextHostPressure"],
            swiftSettings: daemonSwiftSettings
        ),
        // VS Code (Inline): the one `serve-web` server on 127.0.0.1 behind Open Folder in VS Code
        // (Inline) and Stop/Restart VS Code Inline Server. The App opens its URL in a browser tab.
        .target(
            name: "CmuxNextVSCodeServer",
            dependencies: ["CmuxNextWakeups"],
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
        // service: Foundation, Security, Network and CryptoKit only; the App
        // feeds its state to CmuxNextBrowser's CEFRuntimeSource.
        .target(
            name: "CmuxNextChromiumRuntime",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChromiumRuntimeTests",
            dependencies: ["CmuxNextChromiumRuntime"],
            swiftSettings: daemonSwiftSettings
        ),
        // Browser tabs (the App's browser tab domain, moved out leaf-first): the engine a new tab
        // gets (BrowserEngineResolver) and where it goes (BrowserTabRoute). Pure; the App composes it.
        .target(
            name: "CmuxNextBrowserTabs",
            dependencies: ["CmuxNextBrowser", "CmuxNextDaemon", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextChromiumWarmup",
            dependencies: ["CmuxNextBrowser", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChromiumWarmupTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextChromiumWarmup"],
            swiftSettings: uiSwiftSettings
        ),
        // Phone access (Settings > Accounts > Phone Access): the phone host's lifecycle
        // behind phone.allowConnections, the start-workspaces gate and the one-time
        // migration. The App supplies the account and the Mac's name.
        .target(
            name: "CmuxNextPhoneAccess",
            dependencies: ["CmuxNextCompat", "CmuxNextControl", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextKeepAwake",
                           "CmuxNextMobile", "CmuxNextSettings"],
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
            dependencies: ["CmuxNextBrowser", "CmuxNextCompat", "CmuxNextDesign", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPopupsTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextDesign", "CmuxNextPopups"],
            swiftSettings: uiSwiftSettings
        ),
        // The one owner of what happens to a workspace with no pane: a last-tab
        // close closes it, a lost terminal is refilled. The App supplies the
        // daemon's create and close (`EmptyWorkspaceRepair(daemon:)`).
        .target(
            name: "CmuxNextWorkspaceRepair",
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWorkspaceRepairTests",
            dependencies: ["CmuxNextDaemon", "CmuxNextWorkspaceRepair"],
            swiftSettings: uiSwiftSettings
        ),
        // Agent activity (plans/cmux-next/computer-use.md section 7): the
        // pane listing computer use sessions on every machine, their
        // screenshot timeline and user controls. A projection: the CUA host
        // owns every session; the App supplies the source.
        .target(
            name: "CmuxNextAgentActivity",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands")],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/agent-activity"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The thumbnail grid: tiles, the thumbnail cache, drag out, drop reading, Quick Look and the
        // command menu. It reads and changes no files (CmuxNextFiles does). System frameworks only.
        .target(
            name: "CmuxNextFileGrid",
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The Screenshots pane (cmux://screenshots): macOS and screenshot-tool folders, live.
        .target(
            name: "CmuxNextScreenshots",
            dependencies: ["CmuxNextFileGrid", "CmuxNextFiles"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextScreenshotsTests",
            dependencies: ["CmuxNextFileGrid", "CmuxNextFiles", "CmuxNextScreenshots"],
            swiftSettings: uiSwiftSettings
        ),
        // The built-in Memory Inspector (plans/cmux-next/memory-inspector-native-DESIGN.md):
        // one Chief's memory read and changed through a ChiefMemorySource (the app's goes
        // over its daemon connection); model and SwiftUI view, no daemon or AppKit types.
        .target(
            name: "CmuxNextChiefMemory",
            dependencies: ["CmuxNextDesign"],
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
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextChiefViewsTests",
            dependencies: ["CmuxNextAgentActivity", "CmuxNextChiefViews", "CmuxNextPages", "CmuxNextSettings"],
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
            dependencies: ["CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CCmuxAppFFI"],
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
            dependencies: ["CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups"],
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
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextWakeups", "CCmuxAppFFI"],
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
            dependencies: ["CmuxNextDevices", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextRemoteViewTests",
            dependencies: ["CmuxNextRemoteView"],
            swiftSettings: uiSwiftSettings
        ),
        // Remote tab client (remote-tab.md r2): the page of a browser tab
        // whose runtime is on another machine. Decode and present come from
        // CmuxNextRemoteView; session state is the Rust client reducer.
        .target(
            name: "CmuxNextRemoteBrowser",
            dependencies: ["CmuxNextCompat", "CmuxNextRemoteView", "CmuxNextBrowser", "CmuxNextDesign", "CCmuxAppFFI"],
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
            dependencies: ["CmuxNextDesign", "CmuxNextIcons"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // The cmux server's privileged helper (plans/cmux-next/server.md 9.4): the XPC
        // protocol, the fixed allowlist of fixes and the same-team listener. No UI.
        .target(
            name: "CmuxNextServerHelper",
            dependencies: ["CmuxNextCompat"],
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
            dependencies: ["CmuxNextAgentPane", "CmuxNextControl", "CmuxNextDesign", "CmuxNextPages", "CmuxNextSettings", "CmuxNextUpdater", "CmuxNextWakeups"],
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
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // Machines reached over the user's own OpenSSH: destinations, the
        // `cmux-tui remote connect ssh://` link, probe, reconnect gate, the
        // pinned cmux-tui install and the remote-to-local deny policy. No UI.
        .target(
            name: "CmuxNextRemote",
            dependencies: ["CmuxNextCompat", "CmuxNextCloud"],
            swiftSettings: daemonSwiftSettings
        ),
        // App-layer mapping between daemon records and feature view models,
        // kept out of CmuxNextApp so it links in `swift test` (no GhosttyKit).
        .target(
            name: "CmuxNextBridge",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDaemon", "CmuxNextLayout", "CmuxNextSidebar", "CmuxNextTabs", "CmuxNextIcons",
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Back-ports of newer system APIs so that cmux-next runs on macOS 14
        // (plans/cmux-next/macos-floor.md): Mutex (os_unfair_lock) and Atomic
        // (lock-free, swift-atomics) with the Synchronization API.
        .target(
            name: "CmuxNextCompat",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextCompatTests",
            dependencies: ["CmuxNextCompat"],
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
            dependencies: ["CmuxNextErrorJournal"],
            swiftSettings: daemonSwiftSettings
        ),
        // Always-on signpost intervals, one name catalog for Debug and Release benches
        // (plans/cmux-next/architecture-refactor-DESIGN.md section 7).
        .target(
            name: "CmuxNextSignposts",
            // Compat's Atomic: the MetricKit mirror's switch (SignpostMetricKitMirror.swift).
            dependencies: ["CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSignpostsTests",
            dependencies: ["CmuxNextSignposts"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextWakeups",
            // Signposts: the main-thread scheduler's `stall.main_task` and `stall.over_budget` (MainFrameBudget), and
            // the typing probe's key-press flow hops (`key.flow`).
            dependencies: ["CmuxNextCompat", "CmuxNextSignposts"],
            swiftSettings: daemonSwiftSettings
        ),
        // The one test clock of the CmuxNext test targets (ManualClock); test targets only.
        .target(
            name: "CmuxNextWakeupsTestSupport",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        // Install cmux CLI in PATH: the /usr/local/bin link to the bundled CLI
        // (moved out of CmuxNextApp to keep it under its size cap).
        .target(
            name: "CmuxNextCLIInstall",
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
            dependencies: ["CmuxNextCompat"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextHangReportsTests",
            dependencies: ["CmuxNextCompat", "CmuxNextHangReports"],
            swiftSettings: daemonSwiftSettings
        ),
        // Crash and exception reports to Sentry (cx-urd.58): consent, channel
        // environment, release, fingerprint, scrubbing, signal handler order.
        .target(
            name: "CmuxNextCrashReporting",
            dependencies: [
                "CmuxNextCompat",
                .product(name: "CmuxSentryReporting", package: "CmuxSentryTelemetry"),
                .product(name: "Sentry-Dynamic", package: "sentry-cocoa"),
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
        .target(
            name: "CmuxNextDesign",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDesignTokens",
                // The shared overflow button's ⋮ glyph (OverflowButton, action.more.vertical).
                "CmuxNextIcons",
                "CmuxNextWakeups",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
                // cmux-motion's curves and color mix for ColorTransition (cx-3rf4z).
                "CCmuxAppFFI",
            ],
            resources: [.process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        // Theme derivation (Ghostty colors -> chrome tokens), contrast, live reload.
        .testTarget(
            name: "CmuxNextDesignTests",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextDesign",
                "CmuxNextDesignTokens",
                "CmuxNextWakeupsTestSupport",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextActions",
            // Wakeups: the main-thread task board, where an action run is published as a span so the
            // watchdog samples a run past its 10 ms budget (ActionBudgetMonitor).
            dependencies: ["CmuxNextSignposts", "CmuxNextWakeups"],
            resources: [
                .process("AccountsActions.xcstrings"),
                .process("ActionCatalog.xcstrings"),
                .process("AgentConfigurationActions.xcstrings"),
                .process("AppStoreActions.xcstrings"),
                .process("BookmarkActions.xcstrings"),
                .process("BrowserProfileActions.xcstrings"),
                .process("BrowserToolbarActions.xcstrings"),
                .process("CloudPortActions.xcstrings"),
                .process("DevToolsActions.xcstrings"),
                .process("Extensions.xcstrings"),
                .process("HibernationActions.xcstrings"),
                .process("HistoryActions.xcstrings"),
                .process("HangReportsActions.xcstrings"),
                .process("ImportActions.xcstrings"),
                .process("CloudSessionActions.xcstrings"),
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
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextDaemonTests",
            // CmuxNextCompat: the tests import it directly (Mutex); undeclared, an incremental build kept a
            // test object compiled against its older interface (an undefined Mutex.withLock symbol at link).
            dependencies: ["CmuxNextCompat", "CmuxNextDaemon", "CmuxNextWakeupsTestSupport"],
            swiftSettings: daemonSwiftSettings
        ),
        // Links libghostty (GhosttyNextKit, whose macOS archive has the lib
        // prefix, so SwiftPM test bundles link it too).
        .target(
            name: "CmuxNextTerminal",
            dependencies: [
                "CmuxNextCompat",
                "CmuxNextWakeups",
                "CmuxNextProcessEnvironment",
                "CmuxNextDesign",
                "CmuxNextIcons",
                "CmuxNextTerminalGeometry",
                "CmuxNextCopyMode",
                "CmuxNextTerminalFind",
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Terminal tests that need only TerminalSession (the TextBox composer), without the
        // whole App build. libghostty needs libc++, as in CmuxNextAppTests.
        .testTarget(
            name: "CmuxNextTerminalTests",
            dependencies: ["CmuxNextTerminal"],
            swiftSettings: uiSwiftSettings,
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
                "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextResources", "CmuxNextIcons",
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSidebar",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextResources", "CmuxNextIcons", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CCmuxAppFFI"],
            resources: [
                .process("Resources"),
            ],
            // The pinned FFI has the sidebar document mirror (cmux_sidebar_mirror_*, sidebar-doc-v1).
            swiftSettings: uiSwiftSettings + [.define("CMUX_SIDEBAR_MIRROR_FFI")]
        ),
        .target(
            name: "CmuxNextPalette",
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextActions", .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"), "CCmuxAppFFI"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPaletteTests",
            // CmuxTheme: PaletteScopeChipContrastTests derives theme tokens.
            dependencies: ["CmuxNextPalette", .product(name: "CmuxTheme", package: "CmuxTheme")],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextLayout",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextIcons"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Browser tab hibernation policy (Memory Saver): which hidden pages freeze or are
        // discarded and when, from facts the App's BrowserHibernation coordinator feeds it
        // (plans/cmux-next/tab-lifecycle.md). Pure values; no engine, no I/O.
        .target(
            name: "CmuxNextHibernation",
            dependencies: ["CmuxNextCompat", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        // The browser's engine-neutral half: tab and engine values, intents, capability protocols, omnibox
        // and page-info models; no views, no engine (plans/cmux-next/architecture-refactor-DESIGN.md
        // section 8). CmuxNextBrowser depends on it and re-exports it.
        .target(
            name: "CmuxNextBrowserCore",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextBrowser",
            dependencies: ["CmuxNextBrowserCore", "CmuxNextCompat", "CmuxNextWakeups", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextRemoteFetch", "CmuxNextRemoteLayer"],
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
            dependencies: ["CmuxNextBrowser", "CmuxNextTabs"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextCompat", "CmuxNextDesign", "CmuxNextRemoteFetch", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // The WebKit driver for the Rust browser host (plans/cmux-next/browser-host.md).
        .target(
            name: "CmuxNextBrowserAutomation",
            dependencies: ["CmuxNextBrowser", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserAutomationTests",
            dependencies: ["CmuxNextBrowserAutomation"],
            swiftSettings: uiSwiftSettings
        ),
        // The app's provider bridge to the browser host (plans/cmux-next/browser-host.md, step c3).
        .target(
            name: "CmuxNextBrowserHost",
            dependencies: ["CmuxNextCompat", "CmuxNextBrowser", "CmuxNextBrowserAutomation", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserHostTests",
            dependencies: ["CmuxNextBrowser", "CmuxNextBrowserAutomation", "CmuxNextBrowserHost", "CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextRemoteLocalhost",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups"],
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
            dependencies: ["CmuxNextCompat", "CmuxNextDesign", "CmuxNextActions", "CmuxNextWakeups"],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSettingsTests",
            dependencies: ["CmuxNextSettings", "CmuxNextDesign", "CmuxNextActions"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextSettingsWindow",
            dependencies: ["CmuxNextSettings", "CmuxNextDesign", "CmuxNextIcons", "CmuxNextActions", "CmuxNextWakeups"],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextControl",
            dependencies: ["CmuxNextCompat", "CmuxNextWakeups", "CmuxNextProcessEnvironment", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextControlTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextWakeupsTestSupport", "CmuxNextCompat", "CmuxNextControl", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            swiftSettings: daemonSwiftSettings
        ),
        // Settings and palette agent CLI updates (moved out of CmuxNextApp/AgentHarnesses):
        // the shared registry handler, owner routes, intents and terminal outcomes.
        .target(
            name: "CmuxNextAgentUpdates",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextDaemon", "CmuxNextDaemonService", "CmuxNextPages", "CmuxNextSettings"],
            swiftSettings: uiSwiftSettings
        ),
        // Test-only: every exit() of the test process prints its stack (TestProcessExitTests).
        .target(
            name: "CmuxNextTestExitTrace",
            path: "Tests/Support/CmuxNextTestExitTrace"
        ),
        .testTarget(
            name: "CmuxNextAppTests",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxNextActions",
                "CmuxNextAgentCursor",
                "CmuxNextAgentLanes",
                "CmuxNextAgentPermissions",
                "CmuxNextAgentUpdates",
                "CmuxNextApp",
                "CmuxNextApps",
                "CmuxNextBrowserHistory",
                "CmuxNextBrowserImport",
                "CmuxNextBrowserTabs",
                "CmuxNextChiefMemory",
                "CmuxNextChiefPetWiring",
                "CmuxNextChromiumRuntime",
                "CmuxNextCloudCredentials",
                "CmuxNextCompat",
                "CmuxNextComputerUse",
                "CmuxNextCookieImport",
                "CmuxNextCopyMode",
                "CmuxNextCrashReporting",
                "CmuxNextDaemon",
                "CmuxNextDaemonRecovery",
                "CmuxNextDaemonService",
                "CmuxNextDesign",
                "CmuxNextDiff",
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
                "CmuxNextImportCards",
                "CmuxNextImportSuggestions",
                "CmuxNextLayout",
                "CmuxNextMacScreen",
                "CmuxNextMobile",
                "CmuxNextMobileHost",
                "CmuxNextNowPlaying",
                "CmuxNextOnboarding",
                "CmuxNextPagesTestSupport",
                "CmuxNextPalette",
                "CmuxNextProcessEnvironment",
                "CmuxNextRemote",
                "CmuxNextRemoteLocalhostService",
                "CmuxNextRemoteViewSessions",
                "CmuxNextScreenshots",
                "CmuxNextSessionTransfer",
                "CmuxNextSignposts",
                "CmuxNextStash",
                "CmuxNextTabs",
                "CmuxNextTasks",
                "CmuxNextTerminalGeometry",
                "CmuxNextTestExitTrace",
                "CmuxNextVSCodeServer",
                "CmuxNextWakeups",
                "CmuxNextWakeupsTestSupport",
                "CmuxNextWorkspaceNaming",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                // GhosttyGlassMinimumContrastTests builds a Ghostty config.
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                // MacInstallTeamAuthTests signs team challenges with the install key.
                .product(name: "CmuxInstallAuthCore", package: "CmuxInstallAuthCore"),
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
            dependencies: ["CmuxNextMobileHost", "CmuxNextAgentPane", "CmuxNextPages", "CmuxNextSettings"],
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
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextActionsTests",
            dependencies: ["CmuxNextActions"],
            swiftSettings: uiSwiftSettings
        ),
    ] + [appFFI]

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
