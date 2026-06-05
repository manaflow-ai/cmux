// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxUpdater",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxUpdater",
            targets: ["CmuxUpdater"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.1"),
    ],
    targets: [
        .target(
            name: "CmuxUpdater",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxUpdaterTests",
            dependencies: ["CmuxUpdater"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
