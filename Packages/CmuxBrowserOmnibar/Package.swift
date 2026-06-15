// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserOmnibar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserOmnibar",
            targets: ["CmuxBrowserOmnibar"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserOmnibar",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserOmnibarTests",
            dependencies: ["CmuxBrowserOmnibar"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
