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
        // Shared SwiftUI font-scaling helpers for command-list rows.
        .package(path: "../CmuxFoundation"),
        // Pure-logic command-palette domain (overlay promotion policy etc.).
        .package(path: "../CmuxCommandPalette"),
        // Window-chrome overlay install targets + glass effect seam, and the
        // shared passthrough overlay container primitive.
        .package(path: "../CmuxAppKitSupportUI"),
        // DEBUG-only diagnostic logging sink (sanctioned exception).
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxCommandPaletteUI",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCommandPalette", package: "CmuxCommandPalette"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCommandPaletteUITests",
            dependencies: [
                "CmuxCommandPaletteUI",
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
