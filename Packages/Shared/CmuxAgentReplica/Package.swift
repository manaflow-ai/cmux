// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentReplica",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentReplica",
            targets: ["CmuxAgentReplica"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentReplica",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentReplicaTests",
            dependencies: ["CmuxAgentReplica"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
