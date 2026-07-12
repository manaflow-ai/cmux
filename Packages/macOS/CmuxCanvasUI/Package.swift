// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCanvasUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCanvasUI",
            targets: ["CmuxCanvasUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxCanvas"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxAppKitSupportUI"),
    ],
    targets: [
        .target(
            name: "CmuxCanvasUI",
            dependencies: [
                "CmuxCanvas",
                "CmuxFoundation",
                "CmuxAppKitSupportUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCanvasUITests",
            dependencies: [
                "CmuxCanvasUI",
            ]
        ),
    ]
)
