// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxShortcuts",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxShortcuts",
            targets: ["CmuxShortcuts"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxShortcuts",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxShortcutsTests",
            dependencies: ["CmuxShortcuts"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
