// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxConversationUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxConversationUI", targets: ["CmuxConversationUI"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxConversation"),
    ],
    targets: [
        .target(
            name: "CmuxConversationUI",
            dependencies: ["CmuxConversation"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationUITests",
            dependencies: ["CmuxConversationUI", "CmuxConversation"],
            swiftSettings: swiftSettings
        ),
    ]
)
