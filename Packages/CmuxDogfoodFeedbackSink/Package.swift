// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDogfoodFeedbackSink",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDogfoodFeedbackSink",
            targets: ["CmuxDogfoodFeedbackSink"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxDogfoodFeedbackSink",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDogfoodFeedbackSinkTests",
            dependencies: ["CmuxDogfoodFeedbackSink"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
