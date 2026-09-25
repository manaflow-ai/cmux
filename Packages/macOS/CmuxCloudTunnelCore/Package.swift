// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCloudTunnelCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CmuxCloudTunnelCore",
            targets: ["CmuxCloudTunnelCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxCloudTunnelCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(name: "CmuxCloudTunnelCoreTests", dependencies: ["CmuxCloudTunnelCore"]),
    ]
)
