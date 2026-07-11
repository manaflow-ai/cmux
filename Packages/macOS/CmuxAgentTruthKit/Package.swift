// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentTruthKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentTruthKit",
            targets: ["CmuxAgentTruthKit"]
        ),
        .executable(
            name: "agent-transcript-harvest",
            targets: ["agent-transcript-harvest"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAgentReplica"),
    ],
    targets: [
        .target(
            name: "CmuxAgentTruthKit",
            dependencies: ["CmuxAgentReplica"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxAgentTranscriptHarvest",
            dependencies: ["CmuxAgentReplica", "CmuxAgentTruthKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .executableTarget(
            name: "agent-transcript-harvest",
            dependencies: ["CmuxAgentTranscriptHarvest"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentTruthKitTests",
            dependencies: ["CmuxAgentTruthKit"],
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
            name: "CmuxAgentTranscriptHarvestTests",
            dependencies: ["CmuxAgentTranscriptHarvest"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
