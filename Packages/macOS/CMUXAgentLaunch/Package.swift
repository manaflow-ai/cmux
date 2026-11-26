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
    targets: [
        .target(
            name: "CMUXAgentLaunch"
        ),
        .testTarget(
            name: "CMUXAgentLaunchTests",
            dependencies: ["CMUXAgentLaunch"]
        ),
    ]
)
