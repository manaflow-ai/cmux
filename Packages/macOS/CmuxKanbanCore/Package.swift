// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxKanbanCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxKanbanCore",
            targets: ["CmuxKanbanCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxKanbanCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxKanbanCoreTests",
            dependencies: ["CmuxKanbanCore"]
        ),
    ]
)
