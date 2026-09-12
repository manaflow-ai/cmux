// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSocketObservability",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxSocketObservability", targets: ["CmuxSocketObservability"])
    ],
    targets: [
        .target(name: "CmuxSocketStackSampler", publicHeadersPath: "include"),
        .target(
            name: "CmuxSocketObservability",
            dependencies: ["CmuxSocketStackSampler"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxSocketObservabilityTests",
            dependencies: ["CmuxSocketObservability"]
        )
    ]
)
