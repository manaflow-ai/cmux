// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDiffUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxDiffUI", targets: ["CmuxDiffUI"]),
    ],
    dependencies: [
        .package(path: "../CmuxMobileRPC"),
        .package(
            url: "https://github.com/smittytone/HighlighterSwift",
            exact: "3.1.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxDiffUI",
            dependencies: [
                "CmuxMobileRPC",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDiffUITests",
            dependencies: ["CmuxDiffUI", "CmuxMobileRPC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
