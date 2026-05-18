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
        .package(path: "../CMUXAgentVault"),
    ],
    targets: [
        .target(
            name: "CMUXAgentLaunch",
            dependencies: ["CMUXAgentVault"]
        ),
        .testTarget(
            name: "CMUXAgentLaunchTests",
            dependencies: ["CMUXAgentLaunch"]
        ),
    ]
)
