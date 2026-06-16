// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCommandPaletteUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCommandPaletteUI",
            targets: ["CmuxCommandPaletteUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxCommandPaletteUI",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCommandPaletteUITests",
            dependencies: ["CmuxCommandPaletteUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
