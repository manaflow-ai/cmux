// swift-tools-version: 6.2
import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "CMUXAuthCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXAuthCore",
            targets: ["CMUXAuthCore"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXAuthCore",
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "CMUXAuthCoreTests",
            dependencies: ["CMUXAuthCore"],
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
