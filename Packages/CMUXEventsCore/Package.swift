// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXEventsCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXEventsCore",
            targets: ["CMUXEventsCore"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXEventsCore"
        ),
        .testTarget(
            name: "CMUXEventsCoreTests",
            dependencies: ["CMUXEventsCore"]
        ),
    ]
)
