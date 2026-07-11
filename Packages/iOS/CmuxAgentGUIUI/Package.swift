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
        .package(path: "../../Shared/CmuxAgentReplica"),
        .package(path: "../../Shared/CmuxAgentSync"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxAgentGUIProjection",
            dependencies: [
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
                "CmuxAgentGUIProjection",
                "CmuxAgentReplica",
                "CmuxAgentSync",
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
                "CmuxAgentGUIProjection",
                "CmuxAgentGUIUI",
                "CmuxAgentReplica",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
