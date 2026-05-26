// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTrajectory",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CodexTrajectory",
            targets: ["CodexTrajectory"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMarkdown"),
    ],
    targets: [
        .target(
            name: "CodexTrajectory",
            dependencies: [
                .product(name: "CMUXMarkdown", package: "CMUXMarkdown"),
            ]
        ),
        .testTarget(
            name: "CodexTrajectoryTests",
            dependencies: ["CodexTrajectory"]
        ),
    ]
)
