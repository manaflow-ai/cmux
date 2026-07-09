// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentWire",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentWire",
            targets: ["CmuxAgentWire"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxAgentReplica"),
    ],
    targets: [
        .target(
            name: "CmuxAgentWire",
            dependencies: ["CmuxAgentReplica"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentWireTests",
            dependencies: ["CmuxAgentWire", "CmuxAgentReplica"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
