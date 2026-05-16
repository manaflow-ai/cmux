// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXLayout",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CMUXLayout",
            targets: ["CMUXLayout"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXLayout",
            dependencies: [],
            path: "Sources/CMUXLayout",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CMUXLayoutTests",
            dependencies: ["CMUXLayout"],
            path: "Tests/CMUXLayoutTests"
        ),
    ]
)
