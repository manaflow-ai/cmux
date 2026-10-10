// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxConversation",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxConversationCore", targets: ["CmuxConversationCore"]),
        .library(name: "CmuxConversationUI", targets: ["CmuxConversationUI"]),
        .library(name: "CmuxConversationMacUI", targets: ["CmuxConversationMacUI"]),
    ],
    targets: [
        .target(name: "CmuxConversationCore", swiftSettings: swiftSettings),
        .target(name: "CmuxConversationGeometry", swiftSettings: swiftSettings),
        .target(
            name: "CmuxConversationUI",
            dependencies: ["CmuxConversationCore", "CmuxConversationGeometry"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxConversationMacUI",
            dependencies: ["CmuxConversationCore", "CmuxConversationGeometry"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "CmuxConversationLabMac",
            dependencies: ["CmuxConversationMacUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationCoreTests",
            dependencies: ["CmuxConversationCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
