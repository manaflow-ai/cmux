// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentConversation",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "CmuxAgentConversation",
            targets: ["CmuxAgentConversation"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentConversation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentConversationTests",
            dependencies: [
                "CmuxAgentConversation",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
