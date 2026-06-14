// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowser",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowser",
            targets: ["CmuxBrowser"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowser",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserTests",
            dependencies: ["CmuxBrowser"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
