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
