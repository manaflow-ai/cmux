// swift-tools-version: 6.2

import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "CmuxSwiftRenderUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSwiftRenderUI",
            targets: ["CmuxSwiftRenderUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSwiftRender"),
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSwiftRenderUI",
            dependencies: [
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "CmuxSwiftRenderUITests",
            dependencies: ["CmuxSwiftRenderUI"],
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
