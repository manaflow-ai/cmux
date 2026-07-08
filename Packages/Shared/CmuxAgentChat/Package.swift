// swift-tools-version: 6.0

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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxAgentChatTests",
            dependencies: ["CmuxAgentChat"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
