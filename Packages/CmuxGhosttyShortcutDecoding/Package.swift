// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxGhosttyShortcutDecoding",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxGhosttyShortcutDecoding",
            targets: ["CmuxGhosttyShortcutDecoding"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxGhosttyShortcutDecoding",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxGhosttyShortcutDecodingTests",
            dependencies: ["CmuxGhosttyShortcutDecoding"]
        ),
    ]
)
