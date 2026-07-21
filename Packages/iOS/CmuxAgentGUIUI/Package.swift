// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentGUIUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentGUIProjection",
            targets: ["CmuxAgentGUIProjection"]
        ),
        .library(
            name: "CmuxAgentGUIUI",
            targets: ["CmuxAgentGUIUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentReplica"),
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../../Shared/CmuxAgentSync"),
        .package(path: "../../Shared/CmuxAgentWire"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxAgentChatUI"),
    ],
    targets: [
        .target(
            name: "CmuxAgentGUIProjection",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentReplica",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxAgentGUIUI",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentGUIProjection",
                "CmuxAgentChat",
                "CmuxAgentChatUI",
                "CmuxAgentReplica",
                "CmuxAgentSync",
                "CmuxAgentWire",
                "CmuxMobileSupport",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentGUIProjectionTests",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentGUIProjection",
                "CmuxAgentGUIUI",
                "CmuxAgentReplica",
                "CmuxAgentSync",
                "CmuxAgentWire",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
