// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileCampaigns",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileCampaigns",
            targets: ["CmuxMobileCampaigns"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileCampaigns",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileCampaignsTests",
            dependencies: ["CmuxMobileCampaigns"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
