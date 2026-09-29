// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalCore",
            targets: ["CmuxTerminalCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTerminalCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalCoreTests",
            dependencies: ["CmuxTerminalCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
