// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxTestSupport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTestSupport",
            targets: ["CmuxTestSupport"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTestSupportTests",
            dependencies: ["CmuxTestSupport"],
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
