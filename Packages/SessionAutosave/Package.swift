// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SessionAutosave",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SessionAutosave",
            targets: ["SessionAutosave"]
        ),
    ],
    targets: [
        .target(
            name: "SessionAutosave",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "SessionAutosaveTests",
            dependencies: ["SessionAutosave"]
        ),
    ]
)
