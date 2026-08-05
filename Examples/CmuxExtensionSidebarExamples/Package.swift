// swift-tools-version: 6.2

import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "CmuxExtensionSidebarExamples",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CmuxExtensionSidebarExamples",
            targets: ["CmuxExtensionSidebarExamples"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/macOS/CmuxSidebarProviderKit"),
    ],
    targets: [
        .target(
            name: "CmuxExtensionSidebarExamples",
            dependencies: ["CmuxSidebarProviderKit"],
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "CmuxExtensionSidebarExamplesTests",
            dependencies: ["CmuxExtensionSidebarExamples"],
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
