// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDictation",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CmuxDictation",
            targets: ["CmuxDictation"]
        )
    ],
    targets: [
        .target(
            name: "CmuxDictation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault")
            ]
        ),
        .testTarget(
            name: "CmuxDictationTests",
            dependencies: ["CmuxDictation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault")
            ]
        ),
    ]
)
