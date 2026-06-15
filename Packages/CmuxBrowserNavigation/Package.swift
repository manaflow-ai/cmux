// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserNavigation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserNavigation",
            targets: ["CmuxBrowserNavigation"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserNavigation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserNavigationTests",
            dependencies: ["CmuxBrowserNavigation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
