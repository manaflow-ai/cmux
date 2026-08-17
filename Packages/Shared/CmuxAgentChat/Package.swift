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
    dependencies: [
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxAgentChat",
            dependencies: [
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxAgentChatTests",
            dependencies: ["CmuxAgentChat"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
