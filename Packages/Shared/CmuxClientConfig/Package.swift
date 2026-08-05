// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxClientConfig",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxClientConfig",
            targets: ["CmuxClientConfig"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxClientConfig",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxClientConfigTests",
            dependencies: ["CmuxClientConfig"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
