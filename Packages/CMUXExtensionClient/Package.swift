// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXExtensionClient",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXExtensionClient",
            targets: ["CMUXExtensionClient"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxExtensionKit"),
    ],
    targets: [
        .target(
            name: "CMUXExtensionClient",
            dependencies: [
                .product(name: "CmuxExtensionKit", package: "CmuxExtensionKit"),
            ]
        ),
        .testTarget(
            name: "CMUXExtensionClientTests",
            dependencies: ["CMUXExtensionClient"]
        ),
    ]
)
