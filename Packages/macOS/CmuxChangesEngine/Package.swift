// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxChangesEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxChangesEngine",
            targets: ["CmuxChangesEngine"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxChangesEngine",
            dependencies: ["CmuxFoundation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxChangesEngineTests",
            dependencies: ["CmuxChangesEngine", "CmuxFoundation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
