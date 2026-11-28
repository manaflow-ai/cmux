// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileBrowser",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileBrowser",
            targets: ["CmuxMobileBrowser"]
        ),
    ],
    dependencies: [
        // Localized-string helpers (`L10n`). `CmuxMobileSupport` is a leaf with
        // no dependencies, so the browser package stays low in the DAG.
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        // A self-contained, phone-local browser surface. P1 browser state never
        // touches the Mac, so this package sits low in the DAG: it depends only
        // on the leaf `CmuxMobileSupport` and links Foundation/WebKit/SwiftUI.
        .target(
            name: "CmuxMobileBrowser",
            dependencies: [
                "CmuxMobileSupport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileBrowserTests",
            dependencies: ["CmuxMobileBrowser"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
