// swift-tools-version: 6.0

import PackageDescription

// Platform-neutral Home render core (decisions IOS2/IOS3): text measurement
// and wrapping with Core Text, bubble and tail geometry, the fitted spring
// tokens, motion committed as Core Animation animations on plain CALayers,
// the layer tree, scroll and momentum, compose editing state, accessibility
// items and platform-neutral input. Imports Foundation, CoreGraphics,
// CoreText and QuartzCore only (no UIKit, no AppKit), so the iOS host
// (UIKit) and the Mac host (AppKit) embed the same root layer.
//
// Data comes from CmuxHomeCore (TranscriptItem, ConversationSummary,
// Participant); changes leave as CmuxHomeCore `HomeIntent`s (a `HomeOp` with
// its idempotency key). This module adds no model type of its own.
let package = Package(
    name: "CmuxHomeRender",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxHomeRender", targets: ["CmuxHomeRender"]),
    ],
    dependencies: [
        .package(path: "../CmuxHomeCore"),
    ],
    targets: [
        .target(
            name: "CmuxHomeRender",
            dependencies: [.product(name: "CmuxHomeCore", package: "CmuxHomeCore")],
            resources: [.process("Resources/Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeRenderTests",
            dependencies: ["CmuxHomeRender", .product(name: "CmuxHomeCore", package: "CmuxHomeCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
