// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTaskManager",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTaskManager",
            targets: ["CmuxTaskManager"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTaskManager",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTaskManagerTests",
            dependencies: ["CmuxTaskManager"]
        ),
    ]
)
