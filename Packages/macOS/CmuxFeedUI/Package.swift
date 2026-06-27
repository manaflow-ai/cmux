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
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CmuxAppKitSupportUI"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxFeedUI",
            dependencies: [
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
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
