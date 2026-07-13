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
        .package(path: "../CmuxMobileShellModel"),
        // Shared shell DTOs for the mobile diff document and localized strings.
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        // Phone-local WebKit surfaces and their native chrome.
        .target(
            name: "CmuxMobileBrowser",
            dependencies: [
                "CmuxMobileShellModel",
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
