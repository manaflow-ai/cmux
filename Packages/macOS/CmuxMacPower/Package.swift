// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMacPower",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMacPower",
            targets: ["CmuxMacPower"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMacPower",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMacPowerTests",
            dependencies: ["CmuxMacPower"]
        ),
    ]
)
