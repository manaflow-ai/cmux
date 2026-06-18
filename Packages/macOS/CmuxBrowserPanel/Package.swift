// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserPanel",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserPanel",
            targets: ["CmuxBrowserPanel"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserPanel",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserPanelTests",
            dependencies: ["CmuxBrowserPanel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
