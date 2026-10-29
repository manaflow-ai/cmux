// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFilePreviewCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFilePreviewCore",
            targets: ["CmuxFilePreviewCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFilePreviewCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFilePreviewCoreTests",
            dependencies: ["CmuxFilePreviewCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
