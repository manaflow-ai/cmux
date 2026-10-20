// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxSidebarProviderKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebarProviderKit",
            targets: ["CmuxSidebarProviderKit"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarProviderKit",
            dependencies: ["CmuxFoundation"]
        ),
    ]
)
