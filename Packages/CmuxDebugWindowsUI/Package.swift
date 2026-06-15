// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDebugWindowsUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDebugWindowsUI",
            targets: ["CmuxDebugWindowsUI"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxDebugWindowsUI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDebugWindowsUITests",
            dependencies: ["CmuxDebugWindowsUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
