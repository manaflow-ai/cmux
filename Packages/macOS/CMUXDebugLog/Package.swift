// swift-tools-version: 6.2

import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "CMUXDebugLog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CMUXDebugLog",
            targets: ["CMUXDebugLog"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXDebugLog",
            path: "Sources/CMUXDebugLog",
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "CMUXDebugLogTests",
            dependencies: ["CMUXDebugLog"],
            path: "Tests/CMUXDebugLogTests",
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
