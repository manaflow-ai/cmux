// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXSocketProtocol",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXSocketProtocol",
            targets: ["CMUXSocketProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXSocketProtocol"
        ),
        .testTarget(
            name: "CMUXSocketProtocolTests",
            dependencies: ["CMUXSocketProtocol"]
        ),
    ]
)
