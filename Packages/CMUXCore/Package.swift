// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXCore",
    products: [
        .library(
            name: "CMUXCore",
            targets: ["CMUXCore"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXCore"
        ),
        .testTarget(
            name: "CMUXCoreTests",
            dependencies: ["CMUXCore"]
        ),
    ]
)
