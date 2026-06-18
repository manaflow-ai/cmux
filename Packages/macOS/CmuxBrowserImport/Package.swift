// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserImport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserImport",
            targets: ["CmuxBrowserImport"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserImport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserImportTests",
            dependencies: ["CmuxBrowserImport"]
        ),
    ]
)
