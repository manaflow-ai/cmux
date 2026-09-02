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
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxTuiManualIO",
            dependencies: ["CmuxFoundation"],
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
