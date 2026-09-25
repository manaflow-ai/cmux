// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxNotifications",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CmuxNotifications",
            targets: ["CmuxNotifications"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxNotifications",
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
