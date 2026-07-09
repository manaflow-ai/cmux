// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDockExtensions",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDockExtensions",
            targets: ["CmuxDockExtensions"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxDockExtensions"
        ),
        .testTarget(
            name: "CmuxDockExtensionsTests",
            dependencies: ["CmuxDockExtensions"]
        ),
    ]
)
