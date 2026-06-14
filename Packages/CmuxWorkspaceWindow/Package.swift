// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceWindow",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceWindow",
            targets: ["CmuxWorkspaceWindow"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceWindow",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceWindowTests",
            dependencies: [
                "CmuxWorkspaceWindow",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
