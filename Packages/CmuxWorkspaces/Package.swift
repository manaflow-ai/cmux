// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaces",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaces",
            targets: ["CmuxWorkspaces"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaces",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspacesTests",
            dependencies: ["CmuxWorkspaces"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
