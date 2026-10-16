// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMemoryPressure",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMemoryPressure",
            targets: ["CmuxMemoryPressure"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxMemoryPressure",
            dependencies: ["CmuxFoundation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMemoryPressureTests",
            dependencies: ["CmuxMemoryPressure"]
        ),
    ]
)
