// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxCanvasUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCanvasUI",
            targets: ["CmuxCanvasUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxCanvas"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxCanvasUI",
            dependencies: [
                "CmuxCanvas",
                "CmuxFoundation",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCanvasUITests",
            dependencies: [
                "CmuxCanvasUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
