// swift-tools-version: 6.0

import PackageDescription

// The visible-rows contract (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area, right?"), shared by the macOS
// app (CmuxNext) and the iOS app. CmuxVisibleRows is the per-list work meter a list keeps in production (no AppKit, no
// UIKit); CmuxVisibleRowsTesting is the contract test helper and the baseline of lists that do not meet it yet.
let package = Package(
    name: "CmuxVisibleRows",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxVisibleRows", targets: ["CmuxVisibleRows"]),
        .library(name: "CmuxVisibleRowsTesting", targets: ["CmuxVisibleRowsTesting"]),
    ],
    targets: [
        .target(
            name: "CmuxVisibleRows",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxVisibleRowsTesting",
            dependencies: ["CmuxVisibleRows"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxVisibleRowsTests",
            dependencies: ["CmuxVisibleRows", "CmuxVisibleRowsTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
