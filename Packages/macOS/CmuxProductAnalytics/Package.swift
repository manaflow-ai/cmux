// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxProductAnalytics",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxProductAnalytics",
            targets: ["CmuxProductAnalytics"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxProductAnalytics",
            dependencies: ["CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxProductAnalyticsTests",
            dependencies: ["CmuxProductAnalytics", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
