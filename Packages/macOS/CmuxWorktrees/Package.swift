// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorktrees",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorktrees",
            targets: ["CmuxWorktrees"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxWorktrees",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorktreesTests",
            dependencies: ["CmuxWorktrees"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
