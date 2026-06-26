// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAppKitSupportUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAppKitSupportUI",
            targets: ["CmuxAppKitSupportUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxWorkspaces"),
        // SidebarResizerBandPolicy (pure hit-band geometry) backs the resizer controller.
        .package(path: "../CmuxSidebar"),
        // WorkspaceIndicatorStyle + the sidebar/workspace catalog sections back the Sidebar Debug editor.
        .package(path: "../CmuxSettings"),
        // CMUXDebugLog backs the ReleasingWindowController close-teardown logging.
        .package(path: "../CMUXDebugLog"),
        // GitFileStatus backs FileExplorerStyle.gitColor(for:) git-status tinting.
        .package(path: "../CmuxGit"),
        // GhosttyStartupAppearancePreviewProfile/State back the Startup Appearance
        // Debug panel's profile selection and synthetic preview config contents.
        .package(path: "../CmuxTerminalCore"),
        // Bonsplit renders the live tab bars in the Tab Bar Backdrop Lab samples.
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxAppKitSupportUI",
            dependencies: [
                "CmuxFoundation",
                "CmuxWorkspaces",
                .product(name: "CmuxSidebar", package: "CmuxSidebar"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxGit", package: "CmuxGit"),
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAppKitSupportUITests",
            dependencies: ["CmuxAppKitSupportUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
