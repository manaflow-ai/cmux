// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFeedbackUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFeedbackUI",
            targets: ["CmuxFeedbackUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFeedback"),
    ],
    targets: [
        .target(
            name: "CmuxFeedbackUI",
            dependencies: [
                .product(name: "CmuxFeedback", package: "CmuxFeedback"),
            ],
            resources: [
                .process("Resources"),
            ],
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
