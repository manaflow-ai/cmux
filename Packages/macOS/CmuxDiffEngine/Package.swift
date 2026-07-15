// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDiffEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxDiffEngine", targets: ["CmuxDiffEngine"]),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxDiffEngine",
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
            name: "CmuxDiffEngineTests",
            dependencies: ["CmuxDiffEngine"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
