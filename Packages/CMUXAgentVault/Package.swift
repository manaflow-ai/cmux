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
            name: "CMUXAgentVault",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CMUXAgentVaultTests",
            dependencies: ["CMUXAgentVault"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
