// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxNotifications",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxNotifications",
            targets: ["CmuxNotifications"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxCore"),
        .package(path: "../CMUXAgentLaunch"),
    ],
    targets: [
        .target(
            name: "CmuxNotifications",
            dependencies: [
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxNotificationsTests",
            dependencies: ["CmuxNotifications"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
