// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceNavigation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceNavigation",
            targets: ["CmuxWorkspaceNavigation"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceNavigation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceNavigationTests",
            dependencies: ["CmuxWorkspaceNavigation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
