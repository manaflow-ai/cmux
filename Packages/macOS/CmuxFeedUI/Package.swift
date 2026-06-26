// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFeedUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFeedUI",
            targets: ["CmuxFeedUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXAgentLaunch"),
    ],
    targets: [
        .target(
            name: "CmuxFeedUI",
            dependencies: [
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFeedUITests",
            dependencies: ["CmuxFeedUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
