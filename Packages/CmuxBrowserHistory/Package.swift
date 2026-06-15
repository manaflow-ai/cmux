// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserHistory",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserHistory",
            targets: ["CmuxBrowserHistory"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CmuxBrowserHistory",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserHistoryTests",
            dependencies: ["CmuxBrowserHistory"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
