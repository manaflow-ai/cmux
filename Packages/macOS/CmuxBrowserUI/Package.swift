// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserUI",
            targets: ["CmuxBrowserUI"]
        ),
    ],
    dependencies: [
        // CmuxBrowser owns OmnibarSuggestion, the omnibar suggestion domain type
        // the popup renders.
        .package(path: "../CmuxBrowser"),
        // DEBUG-only suggestion-click telemetry routes through CMUXDebugLog
        // (#if DEBUG only), mirroring CmuxBrowser's ReactGrab logging.
        .package(path: "../CMUXDebugLog"),
        // CmuxTestSupport owns CmuxTypingTiming, the DEBUG typing-latency probe the
        // omnibar field logs keystroke spans through (#if DEBUG only).
        .package(path: "../CmuxTestSupport"),
    ],
    targets: [
        .target(
            name: "CmuxBrowserUI",
            dependencies: [
                .product(name: "CmuxBrowser", package: "CmuxBrowser"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserUITests",
            dependencies: [
                "CmuxBrowserUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
