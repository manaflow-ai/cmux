// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserFocus",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserFocus",
            targets: ["CmuxBrowserFocus"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserFocus",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserFocusTests",
            dependencies: ["CmuxBrowserFocus"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
