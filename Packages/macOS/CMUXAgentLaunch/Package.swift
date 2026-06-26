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
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxPanes"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CMUXAgentLaunch",
            dependencies: [
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
                .product(name: "Bonsplit", package: "bonsplit"),
            ]
        ),
        .testTarget(
            name: "CMUXAgentLaunchTests",
            dependencies: ["CMUXAgentLaunch"]
        ),
    ]
)
