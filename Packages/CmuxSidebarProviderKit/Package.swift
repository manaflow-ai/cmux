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
    targets: [
        .target(
            name: "CmuxSidebarProviderKit"
        ),
    ]
)
