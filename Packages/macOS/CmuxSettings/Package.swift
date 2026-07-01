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
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSettings",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ]
        ),
        .testTarget(
            name: "CmuxSettingsTests",
            dependencies: ["CmuxSettings"]
        ),
    ]
)
