// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXDebugLog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CMUXDebugLog",
            targets: ["CMUXDebugLog"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXDebugLog",
            path: "Sources/CMUXDebugLog"
        ),
        .testTarget(
            name: "CMUXDebugLogTests",
            dependencies: ["CMUXDebugLog"],
            path: "Tests/CMUXDebugLogTests"
        ),
    ]
)
