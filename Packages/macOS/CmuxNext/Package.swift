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
//   CmuxNextTerminal -> CmuxGhosttyKit (binary)
//   CmuxNextDesign, CmuxNextActions, CmuxNextDaemon -> system frameworks only
//   CmuxNextSettings -> Design, Actions (cmux.json load/watch/apply)
//   CmuxNextControl -> Actions, Settings, Daemon (app control socket; no UI; Compat/ forwards cmux CLI verbs to cmux-tui)

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
    ],
    targets: [
        .target(
            name: "CmuxNextApp",
            dependencies: [
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
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
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
            name: "CmuxNextDesign",
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextActions",
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextDaemon",
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
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextTabs",
            dependencies: ["CmuxNextDesign"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextTabsTests",
            dependencies: ["CmuxNextTabs"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSidebar",
            dependencies: ["CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSidebarTests",
            dependencies: ["CmuxNextSidebar"],
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
            dependencies: ["CmuxNextDesign"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextLayoutTests",
            dependencies: ["CmuxNextLayout"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextBrowser",
            dependencies: ["CmuxNextDesign"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextBrowserTests",
            dependencies: ["CmuxNextBrowser"],
            swiftSettings: uiSwiftSettings
        ),
        .target(
            name: "CmuxNextSettings",
            dependencies: ["CmuxNextDesign", "CmuxNextActions"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextSettingsTests",
            dependencies: ["CmuxNextSettings", "CmuxNextDesign", "CmuxNextActions"],
            swiftSettings: daemonSwiftSettings
        ),
        .target(
            name: "CmuxNextControl",
            dependencies: ["CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextControlTests",
            dependencies: ["CmuxNextControl", "CmuxNextActions", "CmuxNextSettings", "CmuxNextDaemon"],
            swiftSettings: daemonSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextAppTests",
            dependencies: ["CmuxNextApp", "CmuxNextActions"],
            swiftSettings: uiSwiftSettings,
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(
            name: "CmuxNextActionsTests",
            dependencies: ["CmuxNextActions"],
            swiftSettings: uiSwiftSettings
        ),
    ]
)
