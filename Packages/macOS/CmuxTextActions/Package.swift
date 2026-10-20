// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTextActions",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTextActions",
            targets: ["CmuxTextActions"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTextActions",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTextActionsTests",
            dependencies: ["CmuxTextActions"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
