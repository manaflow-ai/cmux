// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCommandPalette",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCommandPalette",
            targets: ["CmuxCommandPalette"]
        ),
    ],
    dependencies: [
        // CmuxFoundation backs the FocusGuards/ command-palette focus-stealing
        // NSResponder/NSView guards.
        .package(path: "../CmuxFoundation"),
        // CmuxSidebar owns the pure RightSidebarMode data core that the
        // right-sidebar contribution provider maps to palette command IDs.
        .package(path: "../CmuxSidebar"),
        // CmuxPanes owns PanelType, which carries the switcher's surface
        // keyword-kind mapping (PanelType+CommandPaletteSurfaceKeywordKind).
        .package(path: "../CmuxPanes"),
    ],
    targets: [
        .target(
            name: "CmuxCommandPalette",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSidebar", package: "CmuxSidebar"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCommandPaletteTests",
            dependencies: [
                "CmuxCommandPalette",
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
