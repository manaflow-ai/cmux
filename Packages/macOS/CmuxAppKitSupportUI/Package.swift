// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAppKitSupportUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAppKitSupportUI",
            targets: ["CmuxAppKitSupportUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxWorkspaceWindow"),
    ],
    targets: [
        .target(
            name: "CmuxAppKitSupportUI",
            dependencies: [
                "CmuxFoundation",
                "CmuxWorkspaceWindow",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAppKitSupportUITests",
            dependencies: ["CmuxAppKitSupportUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
