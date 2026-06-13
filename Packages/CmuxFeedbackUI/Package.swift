// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFeedbackUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFeedbackUI",
            targets: ["CmuxFeedbackUI"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFeedbackUI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFeedbackUITests",
            dependencies: ["CmuxFeedbackUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
