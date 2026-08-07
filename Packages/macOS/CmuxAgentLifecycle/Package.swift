// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentLifecycle",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentLifecycle",
            targets: ["CmuxAgentLifecycle"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentLifecycle",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentLifecycleTests",
            dependencies: ["CmuxAgentLifecycle"]
        ),
    ]
)
