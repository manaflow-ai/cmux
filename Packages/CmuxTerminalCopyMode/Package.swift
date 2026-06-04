// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalCopyMode",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalCopyMode",
            targets: ["CmuxTerminalCopyMode"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTerminalCopyMode",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalCopyModeTests",
            dependencies: ["CmuxTerminalCopyMode"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
