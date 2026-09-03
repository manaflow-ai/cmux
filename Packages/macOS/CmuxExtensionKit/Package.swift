// swift-tools-version: 6.0
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
        .library(
            name: "CmuxPluginAuthorizationCore",
            targets: ["CmuxPluginAuthorizationCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxPluginAuthorizationCore"
        ),
        .target(
            name: "CmuxExtensionKit",
            dependencies: ["CmuxPluginAuthorizationCore"]
        ),
        .testTarget(
            name: "CmuxExtensionKitTests",
            dependencies: ["CmuxExtensionKit", "CmuxPluginAuthorizationCore"]
        ),
    ]
)
