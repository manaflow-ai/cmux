// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxOrchestration",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxOrchestration",
            targets: ["CmuxOrchestration"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxOrchestration",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxOrchestrationTests",
            dependencies: ["CmuxOrchestration"]
        ),
    ]
)
