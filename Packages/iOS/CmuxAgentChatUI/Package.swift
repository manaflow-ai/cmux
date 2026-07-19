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
        .package(path: "../CmuxMobileSupport"),
        .package(
            url: "https://github.com/raspu/Highlightr.git",
            exact: "2.3.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentChatUI",
            dependencies: [
                "CmuxAgentChat",
                "CmuxMobileSupport",
                .product(name: "Highlightr", package: "Highlightr"),
            ],
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
