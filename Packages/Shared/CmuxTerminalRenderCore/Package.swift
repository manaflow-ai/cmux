// swift-tools-version: 6.0

import PackageDescription

// The renderer-neutral half of the iOS terminal (plans/cmux-next/ios-next/a2-ghostty.md):
// the byte/snapshot source protocol every carrier implements (cmux session
// host over CmuxLink, SSH, fixture replay), and the pure policies of the
// Ghostty renderer (config, font sizing, frame pacing, gestures, workloads).
// No UIKit and no Ghostty, so carriers and tests build anywhere.
let package = Package(
    name: "CmuxTerminalRenderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxTerminalRenderCore", targets: ["CmuxTerminalRenderCore"])],
    dependencies: [
        .package(path: "../CmuxTerminalStream"),
        .package(path: "../CmuxTheme"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalRenderCore",
            dependencies: [
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
                .product(name: "CmuxTheme", package: "CmuxTheme"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxTerminalRenderCoreTests",
            dependencies: ["CmuxTerminalRenderCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
