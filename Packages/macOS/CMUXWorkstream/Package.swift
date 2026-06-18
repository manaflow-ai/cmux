// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXWorkstream",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXWorkstream",
            targets: ["CMUXWorkstream"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXWorkstream"
        ),
        .testTarget(
            name: "CMUXWorkstreamTests",
            dependencies: ["CMUXWorkstream"]
        ),
    ]
)
