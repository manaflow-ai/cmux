// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentConversationUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "CmuxAgentConversationUI",
            targets: ["CmuxAgentConversationUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxAgentConversation"),
    ],
    targets: [
        .target(
            name: "CmuxAgentConversationUI",
            dependencies: [
                .product(name: "CmuxAgentConversation", package: "CmuxAgentConversation"),
            ],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
