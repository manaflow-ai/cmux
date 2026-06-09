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
            type: .dynamic,
            targets: ["CMUXAgentLaunch"]
        ),
        .library(
            name: "CMUXAgentLaunchStatic",
            type: .static,
            targets: ["CMUXAgentLaunch"]
        ),
    ],
    dependencies: [],
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
