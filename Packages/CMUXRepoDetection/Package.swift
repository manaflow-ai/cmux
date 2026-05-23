// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXRepoDetection",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXRepoDetection",
            targets: ["CMUXRepoDetection"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXRepoDetection"
        ),
        .testTarget(
            name: "CMUXRepoDetectionTests",
            dependencies: ["CMUXRepoDetection"]
        ),
    ]
)
