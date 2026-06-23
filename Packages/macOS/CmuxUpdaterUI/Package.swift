// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxUpdaterUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxUpdaterUI",
            targets: ["CmuxUpdaterUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxUpdater"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.1"),
    ],
    targets: [
        .target(
            name: "CmuxUpdaterUI",
            dependencies: [
                "CmuxFoundation",
                "CmuxUpdater",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxUpdaterUITests",
            dependencies: ["CmuxUpdaterUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
