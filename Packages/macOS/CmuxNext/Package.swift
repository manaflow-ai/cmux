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
//   CmuxNextTabs, Sidebar, Layout, Browser -> CmuxNextDesign; Palette -> Design, Actions
//   Feature UI modules never import CmuxNextDaemon; the App maps daemon state into their view models.
//   CmuxNextTerminal -> CmuxNextTerminalGeometry, CmuxNextCopyMode (pure), CmuxGhosttyKit (binary)
//   CmuxNextWakeups -> system frameworks only (the only sanctioned wakeup primitives:
//     FrameScheduler, DemandTimer, Backoff, WakeupLedger; plans/cmux-next/idle-wakeups.md)
//   CmuxNextDesign, CmuxNextActions -> system frameworks only; CmuxNextDaemon -> Wakeups
//   CmuxNextIcons -> system frameworks only (the cmux icon pack, catalog, renderer and Icon view)
//   CmuxNextSettings -> Design, Actions (cmux.json load/watch/apply, SettingsSchema)
//   CmuxNextSettingsWindow -> Settings, Design, Actions, Wakeups (the Settings window, SwiftUI; the App supplies SettingsWindowHost)
//   CmuxNextControl -> Actions, Settings, Daemon (app control socket; no UI; Compat/ forwards cmux CLI verbs to cmux-tui)
//   CmuxNextCloud -> CMUXAuthCore, CmuxAuthRuntime (Stack auth, /api/vm REST,
//     WireGuard hub and cmux-tui remote links; no UI, no daemon)
//   CmuxNextRemote -> CmuxNextCloud (SSH machines: ssh argv, probe, install, relay policy; no UI, no daemon)
//   CmuxNextMobile -> Daemon, CMUXMobileCore, CmuxIrxTransport (phone host; no UI)
//   CmuxNextUpdater -> Design, CmuxUpdater, Sparkle (update checks, appcast probe, update sheet; no daemon)
//   CmuxNextMallocZone -> libSystem only (C: the delegating default malloc zone that lets the
//     Chromium framework load later from another thread; plans/cmux-next/browser-isolation.md)
//   CmuxNextBrowserImport -> system frameworks only (browser detection, parsers, importer; no UI)
//   CmuxNextOnboarding -> Design, BrowserImport (first-run window; the App supplies OnboardingServices)
//   CmuxNextHome -> Design, Wakeups (Home conversations: virtualized CALayer transcript, list, composer;
//     no daemon; the App maps the conversation mirror and intent log into HomeTranscriptSource)
//   CmuxNextHistory -> Design (history model, SQLite visit log, cmux://history page; no daemon)
//   CmuxNextPages -> Design, Settings (the one host for React pages: PageWebView, cmux-page://<id>/
//     scheme, engine-neutral bridge, PageRouter + PageProvider; no daemon; the App supplies providers;
//     plans/cmux-next/react-pages.md)
//   CmuxNextCodeRouter -> CmuxNextCloud (provider sign-in detection, the CodeRouter control-plane
//     client, pasted-key Keychain store, account row state; no UI, no daemon; plans/cmux-next/coderouter.md)
//   CmuxNextAccounts -> CodeRouter, Design (Settings > Accounts and the onboarding step; the App supplies AccountsServices)
//   CmuxNextBookmarks -> Design (bookmark tree per browser profile, Netscape HTML, ranking, file store,
//     cmux://bookmarks page, bookmarks bar, edit bubble; no daemon; the App supplies the store)
//   CmuxNextResources -> Wakeups, Design (hover-card CPU/memory: aggregation, on-demand sampler, lines;
//     no daemon; the App supplies the samples). Tabs and Sidebar show it.
//   CmuxNextAgentPane -> Design, Actions, Dictation (WKWebView host for the React agent pane and the acpmux
//     handshake; the page talks to acpmux itself; no daemon)
//   CmuxNextAgentActivity -> Design (Agent activity pane: computer use sessions, timeline, prototype layouts;
//     a projection of the CUA host; no daemon; the App supplies the source; plans/cmux-next/computer-use.md)
//   CmuxNextApps -> Design (app platform: manifest model, scene store + native renderer, JavaScriptCore
//     prototype engine, prototype registry, App Store window; no daemon; the App supplies the
//     operation sink; plans/cmux-next/app-platform.md)
//   CmuxNextTasks -> Design (Tasks pane: list, board and inbox prototypes over a mirror + intent
//     log of the Tasks owner; no daemon; the App supplies the source; plans/cmux-next/tasks.md)
//   CmuxNextFeed -> Design, Wakeups (feed panel: list, inbox and menu bar prototypes over a mirror + intent
//     log of the feed owner; no daemon; the App supplies the source; plans/cmux-next/feed.md)
//   CmuxNextServer -> Design (server menubar panel, pairing, approver sheet and health prototypes
//     over a projection of `server.status`; no daemon; the App supplies the source;
//     plans/cmux-next/server.md)
//   CmuxNextRemoteView -> Design (remote desktop pane: decode, presenters, chrome, input capture;
//     no daemon; the App supplies the stream source and input sink; plans/cmux-next/remote-desktop.md)
//   CmuxNextServerHelper -> system frameworks only (privileged helper XPC protocol, fix allowlist,
//     same-team listener; plans/cmux-next/server.md 9.4); the App links it for the client side
//   CmuxNextServerHelperDaemon -> ServerHelper (the root helper executable; bundled by
//     scripts/cmux-next/bundle-server-helper.sh, not linked into the App)
//   CmuxNextDictation -> Wakeups (on-device speech: SpeechAnalyzer, SFSpeechRecognizer fallback,
//     the session state machine; no UI)

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

/// The remote desktop viewer core (Rust crate cmux-tui/crates/cmux-rd-ffi) as the
/// client xcframework, linked only into CmuxNextRemoteView and only when
/// CMUX_NEXT_RD_FFI=1 after scripts/cmux-next/build-rd-ffi.sh built it. Every
/// other build compiles the remote view without it: RemoteRdCore is
/// `#if CMUX_RD_FFI` (plans/cmux-next/remote-desktop.md section 3).
/// An environment switch, not a file check: SwiftPM caches the manifest by
/// its environment, so a file check would go stale.
let remoteDesktopCoreLinked = Context.environment["CMUX_NEXT_RD_FFI"] == "1"
let remoteDesktopCoreTargets: [Target] = remoteDesktopCoreLinked
    ? [.binaryTarget(name: "CCmuxRdFFI", path: "../../../cmux-tui/target/cmux-rd-ffi/CCmuxRdFFI.xcframework")]
    : []
let remoteDesktopCoreDependency: [Target.Dependency] = remoteDesktopCoreLinked ? ["CCmuxRdFFI"] : []
/// A compiler define, not `canImport`: a changed define recompiles the
/// module, so switching CMUX_NEXT_RD_FFI in one .build never links stale objects.
let remoteDesktopCoreSettings: [SwiftSetting] = remoteDesktopCoreLinked ? [.define("CMUX_RD_FFI")] : []

let package = Package(
    name: "CmuxNext",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "CmuxNextApp", targets: ["CmuxNextApp"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxGhosttyKit"),
        .package(path: "../../Shared/CMUXAuthCore"),
        .package(path: "../../Shared/CmuxAuthRuntime"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTheme"),
        .package(path: "../../Shared/CmuxHomeCore"),
        .package(path: "../../Shared/CmuxHomeRender"),
        .package(path: "../../Shared/CmuxIrxTransport"),
        // Sparkle driver shared with the legacy app (no bonsplit, no legacy deps).
        .package(path: "../CmuxUpdater"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // Test-only: the shipped iOS app's own RPC decoders verify the compat adapter.
        .package(path: "../../iOS/CmuxMobileRPC"),
        // Test-only: the iOS app's cmux-tui client drives the daemon lane end to end.
        .package(path: "../../iOS/CmuxMobileSSH"),
    ],
    targets: [
        .target(
            name: "CmuxNextApp",
            dependencies: [
                "CmuxNextMallocZone",
                "CmuxNextHome",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                "CmuxNextWakeups",
                "CmuxNextActions",
                "CmuxNextDaemon",
                "CmuxNextDesign",
                "CmuxNextTerminal",
                "CmuxNextTerminalFind",
                "CmuxNextTabs",
                "CmuxNextSidebar",
                "CmuxNextPalette",
                "CmuxNextLayout",
                "CmuxNextBrowser",
                "CmuxNextRemoteLocalhost",
                "CmuxNextBridge",
                "CmuxNextControl",
                "CmuxNextSettings",
                "CmuxNextSettingsWindow",
                "CmuxNextCloud",
                "CmuxNextRemote",
                "CmuxNextMobile",
                "CmuxNextUpdater",
                "CmuxNextResources",
                "CmuxNextBrowserImport",
                "CmuxNextOnboarding",
                "CmuxNextAgentPane",
                "CmuxNextHistory",
                "CmuxNextPages",
                "CmuxNextRemoteView",
                "CmuxNextCodeRouter",
                "CmuxNextAccounts",
                "CmuxNextBookmarks",
                "CmuxNextAgentActivity",
                "CmuxNextApps",
                "CmuxNextTasks",
                "CmuxNextServer",
                "CmuxNextServerHelper",
                "CmuxNextFeed",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Agent pane (plans/cmux-next roadmap Phase 1): hosts the React pane
        // from webviews/src/agent-session/acpmux, built into
        // Resources/agent-pane by scripts/cmux-next/build-agent-pane-web.sh,
        // and answers its versioned handshake (find or start acpmux, endpoint,
        // token, session id). Everything above the handshake is TypeScript.
        .target(
            name: "CmuxNextAgentPane",
            dependencies: ["CmuxNextDesign", "CmuxNextActions", "CmuxNextDictation", "CmuxNextPages", "CmuxNextSettings"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/agent-pane"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAgentPaneTests",
            dependencies: ["CmuxNextAgentPane", "CmuxNextActions", "CmuxNextDesign", "CmuxNextDictation", "CmuxNextPages", "CmuxNextSettings"],
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
        .testTarget(
            name: "CmuxNextDictationTests",
            dependencies: ["CmuxNextDictation"],
            swiftSettings: daemonSwiftSettings
        ),
        // Icons (design/icons): the cmux icon pack and catalog generated by
        // scripts/icons/build_pack.py, the path parser and renderer, the
        // SwiftUI `Icon` view and template NSImages. A leaf: no dependencies.
        .target(
            name: "CmuxNextIcons",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextIconsTests",
            dependencies: ["CmuxNextIcons"],
            swiftSettings: uiSwiftSettings
        ),
        // CodeRouter and provider accounts (plans/cmux-next/coderouter.md):
        // presence-only detection of local sign-ins (Codex, Claude Code, API
        // keys, clouds, local servers), the /api/coderouter control-plane
        // client, the pasted-key Keychain store and the row state machine.
        .target(
            name: "CmuxNextCodeRouter",
            dependencies: ["CmuxNextCloud"],
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
            dependencies: ["CmuxNextCodeRouter", "CmuxNextDesign"],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAccountsTests",
            dependencies: ["CmuxNextAccounts", "CmuxNextCodeRouter"],
            swiftSettings: uiSwiftSettings
        ),
        // Browser import (onboarding step 2; data-model.md 5): source detection
        // (Chrome, Arc, Dia, Brave, Edge, Vivaldi, Helium, Chromium, Safari,
        // Firefox), parsers for bookmarks, history, open tabs and extensions,
        // and the cancellable importer. No UI, nothing main-actor.
        .target(
            name: "CmuxNextBrowserImport",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserImportTests",
            dependencies: ["CmuxNextBrowserImport"],
            swiftSettings: daemonSwiftSettings
        ),
        // First-run onboarding window: theme and density, browser import,
        // default browser and terminal handlers, the key ideas tour. The App
        // supplies `OnboardingServices`.
        .target(
            name: "CmuxNextOnboarding",
            dependencies: ["CmuxNextDesign", "CmuxNextBrowserImport"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextOnboardingTests",
            dependencies: ["CmuxNextOnboarding", "CmuxNextBrowserImport", "CmuxNextDesign"],
            swiftSettings: uiSwiftSettings
        ),
        // Chromium's EarlyMallocZoneRegistration, run first thing in main.
        .target(name: "CmuxNextMallocZone"),
        // Home (plans/cmux-next/home.md section 3): the native conversation
        // renderer (paged window, prefix-sum layout, background raster,
        // render-server send motion), the conversation list and composer.
        .target(
            name: "CmuxNextHome",
            dependencies: [
                "CmuxNextDesign", "CmuxNextWakeups",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CmuxNextHomeTests",
            dependencies: [
                "CmuxNextHome", "CmuxNextDesign",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
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
            dependencies: ["CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextHistoryTests",
            dependencies: ["CmuxNextHistory"],
            swiftSettings: uiSwiftSettings
        ),
        // React pages (plans/cmux-next/react-pages.md): one WKWebView host, one cmux-page://<id>/
        // origin per page, the cmuxPage bridge and the page router. Pages ship as one self-contained
        // index.html each under Resources/pages (scripts/cmux-next/build-pages-web.sh).
        .target(
            name: "CmuxNextPages",
            dependencies: ["CmuxNextDesign", "CmuxNextSettings"],
            resources: [.copy("Resources/pages"), .process("Localizable.xcstrings")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPagesTests",
            dependencies: ["CmuxNextPages", "CmuxNextSettings", "CmuxNextDesign"],
            swiftSettings: uiSwiftSettings
        ),
        // Bookmarks (plans/cmux-next/bookmarks.md): the tree per browser
        // profile, Netscape HTML import/export, omnibar ranking, the local
        // file store, the cmux://bookmarks page, the bookmarks bar and the
        // edit bubble.
        .target(
            name: "CmuxNextBookmarks",
            dependencies: ["CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBookmarksTests",
            dependencies: ["CmuxNextBookmarks"],
            swiftSettings: uiSwiftSettings
        ),
        // Agent activity (plans/cmux-next/computer-use.md section 7): the
        // pane listing computer use sessions on every machine, their
        // screenshot timeline and user controls. A projection: the CUA host
        // owns every session; the App supplies the source.
        .target(
            name: "CmuxNextAgentActivity",
            dependencies: ["CmuxNextDesign", "CmuxNextWakeups"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/agent-activity"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAgentActivityTests",
            dependencies: ["CmuxNextAgentActivity"],
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
            dependencies: ["CmuxNextDesign"],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/AppPlatform"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppsTests",
            dependencies: ["CmuxNextApps"],
            swiftSettings: uiSwiftSettings
        ),
        // App permissions (plans/cmux-next/first-party-apps.md sections 4 and 5):
        // tiers, sandbox profiles, grants and the pure policy, plus the consent
        // sheet, Settings > Apps > Permissions and first-use prompt prototypes.
        // No daemon; the App supplies the data source and the style setting.
        .target(
            name: "CmuxNextAppPermissions",
            dependencies: ["CmuxNextApps", "CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppPermissionsTests",
            dependencies: ["CmuxNextAppPermissions", "CmuxNextApps"],
            swiftSettings: uiSwiftSettings
        ),
        // Tasks (plans/cmux-next/tasks.md): the pane over the team's Tasks
        // owner (a Rust service: cmux-tui/crates/cmux-tasks). A projection:
        // confirmed mirror + intent log; the App supplies the source.
        .target(
            name: "CmuxNextTasks",
            dependencies: ["CmuxNextDesign", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextTasksTests",
            dependencies: ["CmuxNextTasks"],
            swiftSettings: uiSwiftSettings
        ),
        // Feed panel (plans/cmux-next/feed.md section 12): list, inbox and
        // menu bar prototypes over a confirmed mirror + intent log of the
        // feed owner; the App supplies the source.
        .target(
            name: "CmuxNextFeed",
            dependencies: ["CmuxNextDesign", "CmuxNextWakeups"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextFeedTests",
            dependencies: ["CmuxNextFeed"],
            swiftSettings: uiSwiftSettings
        ),
        // Remote desktop pane (plans/cmux-next/remote-desktop.md section 7):
        // VideoToolbox decode, presenter variants, chrome A, input capture and
        // a VideoToolbox mock host. Transport neutral. The App shows it in
        // `remote_view` tabs (cmux://remote-view records, development builds).
        .target(
            name: "CmuxNextRemoteView",
            dependencies: ["CmuxNextDesign"] + remoteDesktopCoreDependency,
            exclude: ["README.md"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings + remoteDesktopCoreSettings
        ),
        .testTarget(
            name: "CmuxNextRemoteViewTests",
            dependencies: ["CmuxNextRemoteView", "CmuxNextDesign"] + remoteDesktopCoreDependency,
            swiftSettings: uiSwiftSettings + remoteDesktopCoreSettings
        ),
        // cmux server (plans/cmux-next/server.md sections 6, 9, 13, 14): the
        // menubar panel, pairing, approver sheet and health prototypes over a
        // projection of `server.status`. The App supplies the source.
        .target(
            name: "CmuxNextServer",
            dependencies: ["CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextServerTests",
            dependencies: ["CmuxNextServer"],
            swiftSettings: uiSwiftSettings
        ),
        // The cmux server's privileged helper (plans/cmux-next/server.md 9.4): the XPC
        // protocol, the fixed allowlist of fixes and the same-team listener. No UI.
        .target(
            name: "CmuxNextServerHelper",
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
        .testTarget(
            name: "CmuxNextServerHelperTests",
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
        .testTarget(
            name: "CmuxNextResourcesTests",
            dependencies: ["CmuxNextResources", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        // Sparkle updates: channel/feed resolution, a read-only appcast probe
        // (dev builds and `updates.check`), and the update sheet.
        .target(
            name: "CmuxNextUpdater",
            dependencies: [
                "CmuxNextDesign",
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextUpdaterTests",
            dependencies: [
                "CmuxNextUpdater",
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        // Cloud machines: auth, REST client, tunnel and link processes. The
        // App turns each connected machine's link socket into a DaemonService.
        .target(
            name: "CmuxNextCloud",
            dependencies: [
                "CmuxNextWakeups",
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextCloudTests",
            dependencies: ["CmuxNextCloud"],
            swiftSettings: daemonSwiftSettings
        ),
        // Machines reached over the user's own OpenSSH: destinations, the
        // `cmux-tui remote connect ssh://` link, probe, reconnect gate, the
        // pinned cmux-tui install and the remote-to-local deny policy. No UI.
        .target(
            name: "CmuxNextRemote",
            dependencies: ["CmuxNextCloud"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextRemoteTests",
            dependencies: ["CmuxNextRemote"],
            swiftSettings: daemonSwiftSettings
        ),
        // App-layer mapping between daemon records and feature view models,
        // kept out of CmuxNextApp so it links in `swift test` (no GhosttyKit).
        .target(
            name: "CmuxNextBridge",
            dependencies: ["CmuxNextDaemon", "CmuxNextLayout", "CmuxNextSidebar", "CmuxNextTabs"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBridgeTests",
            dependencies: ["CmuxNextBridge", "CmuxNextDaemon", "CmuxNextLayout", "CmuxNextSidebar", "CmuxNextTabs"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextWakeups",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextWakeupsTests",
            dependencies: ["CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextDesign",
            dependencies: [
                "CmuxNextWakeups",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
            ],
            resources: [.process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        // Theme derivation (Ghostty colors -> chrome tokens), contrast, live reload.
        .testTarget(
            name: "CmuxNextDesignTests",
            dependencies: [
                "CmuxNextDesign",
                .product(name: "CmuxTheme", package: "CmuxTheme"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextActions",
            resources: [
                .process("AccountsActions.xcstrings"),
                .process("ActionCatalog.xcstrings"),
                .process("AppStoreActions.xcstrings"),
                .process("BookmarkActions.xcstrings"),
                .process("BrowserProfileActions.xcstrings"),
                .process("Extensions.xcstrings"),
                .process("HibernationActions.xcstrings"),
                .process("HistoryActions.xcstrings"),
                .process("LayoutActions.xcstrings"),
                .process("Localizable.xcstrings"),
                .process("PageInfoActions.xcstrings"),
                .process("ProfileActions.xcstrings"),
                .process("RemoteActions.xcstrings"),
                .process("ScreenActions.xcstrings"),
                .process("ServerActions.xcstrings"),
                .process("SettingsActions.xcstrings"),
                .process("SidebarSectionActions.xcstrings"),
                .process("ShortcutRecorder.xcstrings"),
                .process("ThemeActions.xcstrings"),
                .process("WorkspaceActions.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextDaemon",
            dependencies: ["CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextDaemonTests",
            dependencies: ["CmuxNextDaemon"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        // Links the real libghostty only inside the Xcode app target. SwiftPM
        // can compile against the GhosttyKit module but cannot link the macOS
        // archive (it lacks the lib prefix), so this target has no test target
        // until it gets the C-stub pattern used by CmuxTerminalCore.
        .target(
            name: "CmuxNextTerminal",
            dependencies: [
                "CmuxNextWakeups",
                "CmuxNextDesign",
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
        // Pure grid-geometry policy for terminal surfaces (which grid a
        // mirror renders, which grid it reports). No GhosttyKit, so it has
        // tests; CmuxNextTerminal applies it to the live surface.
        .target(
            name: "CmuxNextTerminalGeometry",
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextTerminalGeometryTests",
            dependencies: ["CmuxNextTerminalGeometry"],
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
        .testTarget(
            name: "CmuxNextTerminalFindTests",
            dependencies: ["CmuxNextTerminalFind"],
            swiftSettings: daemonSwiftSettings
        ),
        // Copy mode's vim key table and cursor-box geometry. No GhosttyKit, so
        // it has tests; CmuxNextTerminal drives Ghostty's keyboard-copy API.
        .target(
            name: "CmuxNextCopyMode",
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextCopyModeTests",
            dependencies: ["CmuxNextCopyMode"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextTabs",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign", "CmuxNextResources"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextTabsTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextTabs", "CmuxNextResources"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSidebar",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign", "CmuxNextResources"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSidebarTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextSidebar", "CmuxNextResources"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextPalette",
            dependencies: ["CmuxNextDesign", "CmuxNextActions"],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextPaletteTests",
            dependencies: ["CmuxNextPalette"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextLayout",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextLayoutTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextLayout"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextBrowser",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign"],
            // The CEF shim's C header: its SHA-256 is the shim ABI identity
            // (CEFShimABI, scripts/cmux-next/build-cef-shim.sh).
            resources: [.copy("CEF/Shim/cmux_cef_shim.h"), .process("Resources")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserTests",
            dependencies: ["CmuxNextBrowser"],
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
            dependencies: ["CmuxNextBrowserAutomation", "CmuxNextBrowser"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextRemoteLocalhost",
            dependencies: ["CmuxNextWakeups"],
            resources: [.process("Resources")],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextRemoteLocalhostTests",
            dependencies: ["CmuxNextRemoteLocalhost"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextSettings",
            dependencies: ["CmuxNextDesign", "CmuxNextActions", "CmuxNextWakeups"],
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
            dependencies: ["CmuxNextSettings", "CmuxNextDesign", "CmuxNextActions", "CmuxNextWakeups"],
            resources: [
                .process("Localizable.xcstrings"),
                .copy("Resources/settings-page"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSettingsWindowTests",
            dependencies: ["CmuxNextSettingsWindow", "CmuxNextSettings", "CmuxNextDesign", "CmuxNextActions"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextControl",
            dependencies: ["CmuxNextWakeups", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            resources: [
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextControlTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextControl", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextApp", "CmuxNextActions", "CmuxNextHistory", "CmuxNextCopyMode",
                           "CmuxNextDaemon", .product(name: "CmuxHomeCore", package: "CmuxHomeCore")],
            swiftSettings: uiSwiftSettings,
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // Phone access (plans/cmux-next/cloud-ios.md): irx host, the daemon
        // lane splice, and the mobile.* compat adapter for shipped iOS builds.
        // No UI; the App wires it to the daemon connection and auth.
        .target(
            name: "CmuxNextMobile",
            dependencies: [
                "CmuxNextDaemon",
                "CmuxNextWakeups",
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxIrxTransport", package: "CmuxIrxTransport"),
            ],
            swiftSettings: daemonSwiftSettings
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
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextActionsTests",
            dependencies: ["CmuxNextActions"],
            swiftSettings: uiSwiftSettings
        ),
    ] + remoteDesktopCoreTargets
)
