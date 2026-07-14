// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileDiff",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileDiff", targets: ["CmuxMobileDiff"]),
    ],
    dependencies: [
        .package(path: "../CmuxMobileRPC"),
        .package(path: "../CmuxMobileShell"),
        .package(url: "https://github.com/smittytone/HighlighterSwift", from: "3.1.0"),
    ],
    targets: [
        .target(
            name: "CmuxMobileDiff",
            dependencies: [
                "CmuxMobileRPC",
                "CmuxMobileShell",
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
            name: "CmuxMobileDiffTests",
            dependencies: ["CmuxMobileDiff", "CmuxMobileRPC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
