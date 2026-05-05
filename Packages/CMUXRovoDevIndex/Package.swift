// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXRovoDevIndex",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXRovoDevIndex",
            targets: ["CMUXRovoDevIndex"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXRovoDevIndex"
        ),
        .testTarget(
            name: "CMUXRovoDevIndexTests",
            dependencies: ["CMUXRovoDevIndex"]
        ),
    ]
)
