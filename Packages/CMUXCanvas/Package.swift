// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXCanvas",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CMUXCanvas",
            targets: ["CMUXCanvas"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXLayout"),
    ],
    targets: [
        .target(
            name: "CMUXCanvas",
            dependencies: [
                .product(name: "CMUXLayout", package: "CMUXLayout"),
            ],
            path: "Sources/CMUXCanvas"
        ),
        .testTarget(
            name: "CMUXCanvasTests",
            dependencies: ["CMUXCanvas"],
            path: "Tests/CMUXCanvasTests"
        ),
    ]
)
