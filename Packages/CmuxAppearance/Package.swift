// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxAppearance",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxAppearance", targets: ["CmuxAppearance"])
    ],
    targets: [
        .target(name: "CmuxAppearance"),
        .testTarget(
            name: "CmuxAppearanceTests",
            dependencies: ["CmuxAppearance"]
        )
    ]
)
