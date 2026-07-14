// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSimulator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSimulator",
            targets: ["CmuxSimulator"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxSimulator",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSimulatorTests",
            dependencies: [
                "CmuxSimulator",
            ]
        ),
    ]
)
