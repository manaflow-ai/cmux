// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFeedUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFeedUI",
            targets: ["CmuxFeedUI"]
        ),
    ],
    dependencies: [
        // CMUXAgentLaunch owns the Workstream value snapshots (WorkstreamContext,
        // WorkstreamSource, WorkstreamAllowedPrompt, WorkstreamPlanBlocks,
        // WorkstreamTaskTodo) these presentation views render.
        .package(path: "../CMUXAgentLaunch"),
        // CmuxAppKitSupportUI owns shared AppKit-backed SwiftUI layout helpers
        // (WrapHStack) that the question option-pill grid lays out with.
        .package(path: "../CmuxAppKitSupportUI"),
    ],
    targets: [
        .target(
            name: "CmuxFeedUI",
            dependencies: [
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFeedUITests",
            dependencies: [
                "CmuxFeedUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
