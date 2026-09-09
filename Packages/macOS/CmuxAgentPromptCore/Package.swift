// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentPromptCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentPromptCore",
            targets: ["CmuxAgentPromptCore"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
    ],
    targets: [
        .target(
            name: "CmuxAgentPromptCore",
            dependencies: [
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentPromptCoreTests",
            dependencies: [
                "CmuxAgentPromptCore",
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(
                    name: "CmuxTerminalCoreTestSupport",
                    package: "CmuxTerminalCore"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
