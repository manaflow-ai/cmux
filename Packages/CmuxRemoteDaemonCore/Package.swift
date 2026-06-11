// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRemoteDaemonCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRemoteDaemonCore",
            targets: ["CmuxRemoteDaemonCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxRemoteDaemonCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxRemoteDaemonCoreTests",
            dependencies: ["CmuxRemoteDaemonCore"]
        ),
    ]
)
