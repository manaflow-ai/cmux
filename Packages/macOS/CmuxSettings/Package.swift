// swift-tools-version: 6.2

import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "CmuxSettings",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSettings",
            targets: ["CmuxSettings"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSettings",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "CmuxSettingsTests",
            dependencies: ["CmuxSettings"],
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
