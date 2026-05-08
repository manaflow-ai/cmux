// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXCmxProtocol",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXCmxProtocol",
            targets: ["CMUXCmxProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXCmxProtocol",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "CMUXCmxProtocolTests",
            dependencies: ["CMUXCmxProtocol"]
        ),
    ]
)
