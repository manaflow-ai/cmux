// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXAuthCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXAuthCore",
            targets: ["CMUXAuthCore"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXAuthCore"
        ),
        .testTarget(
            name: "CMUXAuthCoreTests",
            dependencies: ["CMUXAuthCore"]
        ),
    ]
)
