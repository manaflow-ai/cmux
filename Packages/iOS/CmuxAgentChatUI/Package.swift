// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentChatUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentChatUI",
            targets: ["CmuxAgentChatUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAgentChat"),
    ],
    targets: [
        .target(
            name: "CmuxAgentChatUI",
            dependencies: ["CmuxAgentChat"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxAgentChatUITests",
            dependencies: ["CmuxAgentChatUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
