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
        .package(path: "../CmuxCore"),
    ],
    targets: [
        .target(
            name: "CmuxSettings",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCore", package: "CmuxCore"),
            ]
        ),
        .testTarget(
            name: "CmuxSettingsTests",
            dependencies: ["CmuxSettings"]
        ),
    ]
)
