// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXAgentVault",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXAgentVault",
            targets: ["CMUXAgentVault"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXAgentVault"
        ),
        .testTarget(
            name: "CMUXAgentVaultTests",
            dependencies: ["CMUXAgentVault"]
        ),
    ]
)
