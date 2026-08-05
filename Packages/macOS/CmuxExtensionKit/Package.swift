// swift-tools-version: 6.2
import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "CmuxExtensionKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxExtensionKit",
            targets: ["CmuxExtensionKit"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxExtensionKit",
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "CmuxExtensionKitTests",
            dependencies: ["CmuxExtensionKit"],
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
