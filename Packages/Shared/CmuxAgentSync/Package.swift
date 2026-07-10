// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentSync",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentSync",
            targets: ["CmuxAgentSync"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxAgentReplica"),
        .package(path: "../CmuxAgentWire"),
    ],
    targets: [
        .target(
            name: "CmuxAgentSync",
            dependencies: [
                "CmuxAgentReplica",
                "CmuxAgentWire",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentSyncTests",
            dependencies: [
                "CmuxAgentSync",
                "CmuxAgentReplica",
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
