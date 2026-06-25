// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserUI",
    defaultLocalization: "en",
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
        // CmuxSettings owns BrowserThemeMode, the value the theme-mode popover
        // renders and selects.
        .package(path: "../CmuxSettings"),
        // CmuxFoundation owns the shared `Image.cmuxSymbolRasterSize` helper the
        // theme popover's checkmark glyph rasterizes through (one shared helper
        // reused across UI packages instead of a per-package copy).
        .package(path: "../CmuxFoundation"),
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
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
            ],
            resources: [
                // Localized strings for the browser-data import wizard, moved
                // from the app target with the wizard UI so `.module` resolves
                // them in this package's bundle.
                .process("Import/Resources"),
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
