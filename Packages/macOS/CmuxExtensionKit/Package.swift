// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxExtensionKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CmuxExtensionKit",
            targets: ["CmuxExtensionKit"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxExtensionKit"
        ),
        .testTarget(
            name: "CmuxExtensionKitTests",
            dependencies: ["CmuxExtensionKit"]
        ),
    ]
)
