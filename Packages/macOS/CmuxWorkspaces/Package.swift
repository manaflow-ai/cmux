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
    dependencies: [
        // WorkspaceGroupNewPlacement (the typed setting value for new
        // in-group workspace placement) is owned by CmuxSettings.
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaces",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ],
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
