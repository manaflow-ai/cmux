// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFeedback",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFeedback",
            targets: ["CmuxFeedback"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFeedback",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFeedbackTests",
            dependencies: ["CmuxFeedback"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
