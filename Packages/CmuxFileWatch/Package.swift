// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFileWatch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFileWatch",
            targets: ["CmuxFileWatch"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFileWatch",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFileWatchTests",
            dependencies: ["CmuxFileWatch"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
