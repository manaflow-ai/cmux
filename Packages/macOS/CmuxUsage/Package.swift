// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxUsage",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxUsage",
            targets: ["CmuxUsage"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxUsage",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxUsageTests",
            dependencies: ["CmuxUsage"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
