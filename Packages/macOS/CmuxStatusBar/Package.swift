// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxStatusBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxStatusBar",
            targets: ["CmuxStatusBar"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxStatusBar",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxStatusBarTests",
            dependencies: ["CmuxStatusBar"]
        ),
    ]
)
