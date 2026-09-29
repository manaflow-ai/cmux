// swift-tools-version: 6.2

import PackageDescription

// Umbrella package for the cmux-next app (plans/cmux-next/shell.md).
// The Xcode target `cmux-next` compiles only App/main.swift and links the
// `CmuxNextApp` product; every other line of app code lives here, split into
// modules so later agents can work on them in parallel.
//
// Dependency direction (no cycles, no upward imports):
//   CmuxNextApp -> CmuxNextActions, CmuxNextDesign, CmuxNextDaemon, CmuxNextTerminal
//   CmuxNextTerminal -> CmuxGhosttyKit (binary)
//   CmuxNextDesign, CmuxNextActions, CmuxNextDaemon -> system frameworks only

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
            ],
            resources: [
                .process("Resources"),
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
        // Links the real libghostty only inside the Xcode app target. SwiftPM
        // can compile against the GhosttyKit module but cannot link the macOS
        // archive (it lacks the lib prefix), so this target has no test target
        // until it gets the C-stub pattern used by CmuxTerminalCore.
        .target(
            name: "CmuxNextTerminal",
            dependencies: [
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
            ],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "CmuxNextActionsTests",
            dependencies: ["CmuxNextActions"],
            swiftSettings: uiSwiftSettings
        ),
    ]
)
