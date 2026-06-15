// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserControl",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserControl",
            targets: ["CmuxBrowserControl"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserControl",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserControlTests",
            dependencies: ["CmuxBrowserControl"]
        ),
    ]
)
