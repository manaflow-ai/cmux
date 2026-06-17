// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceCore",
            targets: ["CmuxWorkspaceCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceCoreTests",
            dependencies: ["CmuxWorkspaceCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
