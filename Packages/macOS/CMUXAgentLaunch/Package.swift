// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXAgentLaunch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXAgentLaunch",
            targets: ["CMUXAgentLaunch"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CMUXAgentLaunch",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ]
        ),
        .testTarget(
            name: "CMUXAgentLaunchTests",
            dependencies: ["CMUXAgentLaunch"]
        ),
    ]
)
