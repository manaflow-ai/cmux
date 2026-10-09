// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXDebugLog",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CMUXDebugLog",
            targets: ["CMUXDebugLog"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CMUXDebugLog",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            path: "Sources/CMUXDebugLog"
        ),
        .testTarget(
            name: "CMUXDebugLogTests",
            dependencies: ["CMUXDebugLog"],
            path: "Tests/CMUXDebugLogTests"
        ),
    ]
)
