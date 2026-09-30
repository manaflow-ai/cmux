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
//   CmuxNextTerminal -> CmuxNextTerminalGeometry (pure), CmuxGhosttyKit (binary)
//   CmuxNextWakeups -> system frameworks only (the only sanctioned wakeup primitives:
//     FrameScheduler, DemandTimer, Backoff, WakeupLedger; plans/cmux-next/idle-wakeups.md)
//   CmuxNextDesign, CmuxNextActions -> system frameworks only; CmuxNextDaemon -> Wakeups
//   CmuxNextSettings -> Design, Actions (cmux.json load/watch/apply)
//   CmuxNextControl -> Actions, Settings, Daemon (app control socket; no UI; Compat/ forwards cmux CLI verbs to cmux-tui)
//   CmuxNextCloud -> CMUXAuthCore, CmuxAuthRuntime (Stack auth, /api/vm REST,
//     WireGuard hub and cmux-tui remote links; no UI, no daemon)
//   CmuxNextMobile -> Daemon, CMUXMobileCore, CmuxIrxTransport (phone host; no UI)
//   CmuxNextUpdater -> Design, CmuxUpdater, Sparkle (update checks, appcast probe, update sheet; no daemon)

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
                "CmuxNextWakeups",
                "CmuxNextActions",
                "CmuxNextDaemon",
                "CmuxNextDesign",
                "CmuxNextTerminal",
                "CmuxNextTabs",
                "CmuxNextSidebar",
                "CmuxNextPalette",
                "CmuxNextLayout",
                "CmuxNextBrowser",
                "CmuxNextBridge",
                "CmuxNextControl",
                "CmuxNextSettings",
                "CmuxNextCloud",
                "CmuxNextMobile",
                "CmuxNextUpdater",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
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
            dependencies: ["CmuxNextWakeups"],
            swiftSettings: uiSwiftSettings
        ),
        // Theme derivation (Ghostty colors -> chrome tokens), contrast, live reload.
        .testTarget(
            name: "CmuxNextDesignTests",
            dependencies: ["CmuxNextDesign"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextActions",
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
        .target(
            name: "CmuxNextTabs",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextTabsTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextTabs"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSidebar",
            dependencies: ["CmuxNextWakeups", "CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSidebarTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextSidebar"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextPalette",
            dependencies: ["CmuxNextDesign", "CmuxNextActions"],
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
            resources: [.copy("CEF/Shim/cmux_cef_shim.h")],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserTests",
            dependencies: ["CmuxNextBrowser"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSettings",
            dependencies: ["CmuxNextDesign", "CmuxNextActions", "CmuxNextWakeups"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSettingsTests",
            dependencies: ["CmuxNextSettings", "CmuxNextDesign", "CmuxNextActions"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextControl",
            dependencies: ["CmuxNextWakeups", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextControlTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextControl", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppTests",
            dependencies: ["CmuxNextWakeups", "CmuxNextApp", "CmuxNextActions"],
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
    ]
)
