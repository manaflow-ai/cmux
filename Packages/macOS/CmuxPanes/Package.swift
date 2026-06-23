// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxPanes",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxPanes",
            targets: ["CmuxPanes"]
        ),
    ],
    dependencies: [
        .package(path: "../../../vendor/bonsplit"),
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CMUXProjectModel"),
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxTerminalCore"),
    ],
    targets: [
        .target(
            name: "CmuxPanes",
            dependencies: [
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CMUXProjectModel", package: "CMUXProjectModel"),
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                // The split/resize/goto direction converters
                // (SplitDirection.init?(ghosttyDirection:),
                // ResizeDirection.init?(ghosttyDirection:),
                // NavigationDirection.init?(ghosttyGotoSplit:)) map the
                // ghostty_action_*_e C enums onto Bonsplit-side value types, so
                // CmuxPanes needs the GhosttyKit module. CmuxTerminalCore
                // re-vends the single GhosttyKit binaryTarget as CmuxGhosttyKit;
                // depend on that product rather than declaring a duplicate
                // binary target for the one xcframework.
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPanesTests",
            dependencies: ["CmuxPanes"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
