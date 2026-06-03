// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CmuxExtensionKit",
    platforms: [
        .macOS(.v14),
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
