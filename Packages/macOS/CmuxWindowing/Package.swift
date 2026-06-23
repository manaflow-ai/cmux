// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWindowing",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWindowing",
            targets: ["CmuxWindowing"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxWindowing",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWindowingTests",
            dependencies: ["CmuxWindowing"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
