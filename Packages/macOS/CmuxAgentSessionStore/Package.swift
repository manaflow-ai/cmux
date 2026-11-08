// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentSessionStore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentSessionStore",
            targets: ["CmuxAgentSessionStore"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXAgentLaunch"),
    ],
    targets: [
        .target(
            name: "CmuxAgentSessionStore",
            dependencies: [
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentSessionStoreTests",
            dependencies: ["CmuxAgentSessionStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
