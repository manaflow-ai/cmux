// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSettings",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSettings",
            targets: ["CmuxSettings"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFileWatch"),
    ],
    targets: [
        .target(
            name: "CmuxSettings",
            dependencies: [
                .product(name: "CmuxFileWatch", package: "CmuxFileWatch"),
            ]
        ),
        .testTarget(
            name: "CmuxSettingsTests",
            dependencies: ["CmuxSettings"]
        ),
    ]
)
