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
        // Paired domain package: the browser top-chrome views moved here in
        // later slices render CmuxBrowser models.
        .package(path: "../CmuxBrowser"),
        // CmuxFoundation owns CmuxGhosttyConfigSettingEditor, the source of the
        // default surface tab-bar font size BrowserChromeMetrics scales against.
        .package(path: "../CmuxFoundation"),
        // CmuxSettings owns BrowserSearchConfiguration, read by the omnibar
        // suggestions coordinator's host seam.
        .package(path: "../CmuxSettings"),
        // CMUXDebugLog backs the omnibar suggestion-click DEBUG logging (#if DEBUG only).
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxBrowserUI",
            dependencies: [
                .product(name: "CmuxBrowser", package: "CmuxBrowser"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserUITests",
            dependencies: ["CmuxBrowserUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
