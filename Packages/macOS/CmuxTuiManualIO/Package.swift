// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTuiManualIO",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTuiManualIO",
            targets: ["CmuxTuiManualIO"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTuiManualIO",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTuiManualIOTests",
            dependencies: ["CmuxTuiManualIO"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
