// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CmuxSettings",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CmuxSettings",
            targets: ["CmuxSettings"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxSettings",
            path: "Sources/CmuxSettings"
        ),
        .testTarget(
            name: "CmuxSettingsTests",
            dependencies: ["CmuxSettings"],
            path: "Tests/CmuxSettingsTests"
        ),
    ]
)
