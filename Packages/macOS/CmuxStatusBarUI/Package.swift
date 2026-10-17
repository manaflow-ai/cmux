// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxStatusBarUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxStatusBarUI",
            targets: ["CmuxStatusBarUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxStatusBar"),
    ],
    targets: [
        .target(
            name: "CmuxStatusBarUI",
            dependencies: [
                .product(name: "CmuxStatusBar", package: "CmuxStatusBar"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxStatusBarUITests",
            dependencies: [
                "CmuxStatusBarUI",
                .product(name: "CmuxStatusBar", package: "CmuxStatusBar"),
            ]
        ),
    ]
)
