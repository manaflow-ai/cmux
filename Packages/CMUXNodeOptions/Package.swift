// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXNodeOptions",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXNodeOptions",
            targets: ["CMUXNodeOptions"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXNodeOptions",
            path: "Sources/CMUXNodeOptions"
        ),
    ]
)
