// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFeedback",
    defaultLocalization: "en",
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
            resources: [
                // Folded from CmuxFeedbackUI: the composer's localized strings.
                .process("ComposerUI/Resources"),
            ],
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
