// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTextMatching",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTextMatching",
            targets: ["CmuxTextMatching"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTextMatching",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTextMatchingTests",
            dependencies: ["CmuxTextMatching"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
