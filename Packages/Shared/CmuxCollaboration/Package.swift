// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCollaboration",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCollaboration",
            targets: ["CmuxCollaboration"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxCollaboration",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCollaborationTests",
            dependencies: ["CmuxCollaboration"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
