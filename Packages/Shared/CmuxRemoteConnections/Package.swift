// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRemoteConnections",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRemoteConnections",
            targets: ["CmuxRemoteConnections"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxRemoteConnections",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxRemoteConnectionsTests",
            dependencies: ["CmuxRemoteConnections"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
