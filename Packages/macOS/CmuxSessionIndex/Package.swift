// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSessionIndex",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSessionIndex",
            targets: ["CmuxSessionIndex"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXAgentLaunch"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSessionIndex",
            dependencies: [
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSessionIndexTests",
            dependencies: ["CmuxSessionIndex"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
