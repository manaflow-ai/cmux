// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxWindowing",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWindowing",
            targets: ["CmuxWindowing"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWindowing",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWindowingTests",
            dependencies: ["CmuxWindowing"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
