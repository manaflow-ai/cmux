// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxComputerUseVisuals",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxComputerUseVisuals",
            targets: ["CmuxComputerUseVisuals"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxComputerUseVisuals",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .executableTarget(
            name: "GenerateComputerUseHelperIcon",
            dependencies: ["CmuxComputerUseVisuals"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxComputerUseVisualsTests",
            dependencies: ["CmuxComputerUseVisuals"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
