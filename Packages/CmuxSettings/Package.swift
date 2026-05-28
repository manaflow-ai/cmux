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
    targets: [
        .target(
            name: "CmuxSettings"
        ),
        .testTarget(
            name: "CmuxSettingsTests",
            dependencies: ["CmuxSettings"]
        ),
    ]
)
