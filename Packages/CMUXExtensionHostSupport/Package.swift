// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXExtensionHostSupport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXExtensionHostSupport",
            targets: ["CMUXExtensionHostSupport"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxExtensionKit"),
    ],
    targets: [
        .target(
            name: "CMUXExtensionHostSupport",
            dependencies: [
                .product(name: "CmuxExtensionKit", package: "CmuxExtensionKit"),
            ]
        ),
    ]
)
