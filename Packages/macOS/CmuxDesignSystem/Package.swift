// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDesignSystem",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDesignSystem",
            targets: ["CmuxDesignSystem"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxDesignSystem",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDesignSystemTests",
            dependencies: ["CmuxDesignSystem"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
