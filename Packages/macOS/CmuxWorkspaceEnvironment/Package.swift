// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceEnvironment",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceEnvironment",
            targets: ["CmuxWorkspaceEnvironment"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceEnvironment",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceEnvironmentTests",
            dependencies: ["CmuxWorkspaceEnvironment"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
