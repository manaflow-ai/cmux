// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxConversationUI",
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
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationUITests",
            dependencies: ["CmuxConversationUI"],
            swiftSettings: swiftSettings
        ),
    ]
)
