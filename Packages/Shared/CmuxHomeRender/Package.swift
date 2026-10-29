// swift-tools-version: 6.2

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
        // blockingCall for the thumbnail reads.
        .package(path: "../CmuxThreading"),
        .package(path: "../CmuxFuzzSupport"),
        // Invariant: CrashGuard's faults report through notFatalUntil.
        // OnceContinuation, the continuation that resumes exactly once.
        .package(path: "../CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "CmuxHomeRender",
            dependencies: [
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                .product(name: "CmuxThreading", package: "CmuxThreading"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeRenderTests",
            dependencies: [
                "CmuxHomeRender",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxHomeRender",
            "CmuxHomeRenderTests",
        ],
        settings: [
            .strictMemorySafety(),
        ]
    ),
]
for group in stabilitySettingGroups {
    for target in package.targets where group.targets.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + group.settings
    }
}
// END apply-stability-settings.py
