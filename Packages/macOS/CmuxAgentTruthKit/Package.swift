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
    ]
)
