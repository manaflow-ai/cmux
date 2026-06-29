// swift-tools-version: 6.0

import PackageDescription

// CmuxChatLab is a DEBUG-only, fixture-driven chat surface built from scratch
// to chase "Telegram levels of polish" on the two things SwiftUI cannot do
// reliably: pixel-perfect interactive keyboard tracking and jump-free history
// prepend. The message list, composer, and keyboard handling are all UIKit
// (guarded by `canImport(UIKit)`); the fixtures and the sync math are
// platform-agnostic so they unit-test on the macOS host via `swift test`.
//
// It reuses only the shared `CmuxAgentChat` data model. It deliberately does
// NOT depend on `CmuxAgentChatUI` (the existing notification-driven chat UI is
// treated as a non-reference).
let package = Package(
    name: "CmuxChatLab",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxChatLab",
            targets: ["CmuxChatLab"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
    ],
    targets: [
        .target(
            name: "CmuxChatLab",
            dependencies: [
                "CmuxAgentChat",
                .product(name: "Nuke", package: "Nuke"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxChatLabTests",
            dependencies: ["CmuxChatLab"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
