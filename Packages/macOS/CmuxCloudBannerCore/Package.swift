// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCloudBannerCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCloudBannerCore",
            targets: ["CmuxCloudBannerCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxCloudBannerCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCloudBannerCoreTests",
            dependencies: ["CmuxCloudBannerCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
