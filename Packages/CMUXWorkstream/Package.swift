// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXWorkstream",
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
