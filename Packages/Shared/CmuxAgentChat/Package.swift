// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxAgentChat",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentChat",
            targets: ["CmuxAgentChat"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentChat",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("InferIsolatedConformances"), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(
            name: "CmuxAgentChatTests",
            dependencies: ["CmuxAgentChat"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("InferIsolatedConformances"), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ]
)
