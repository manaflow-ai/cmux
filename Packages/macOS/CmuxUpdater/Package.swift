// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxUpdater",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxUpdater",
            targets: ["CmuxUpdater"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "CmuxUpdater",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxUpdaterTests",
            dependencies: [
                "CmuxUpdater",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
