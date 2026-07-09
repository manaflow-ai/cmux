// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebarUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebarUI",
            targets: ["CmuxSidebarUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSidebar"),
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxFoundation"),
        // CmuxExtensionScope/CmuxExtensionActionScope back the permission-row
        // display-name and description copy in Extension/.
        .package(path: "../CmuxExtensionKit"),
        // ExtensionSidebarBrowserStackDropRow/Planner + CmuxSidebarProviderWorkspaceMove
        // back the extension browser-stack drop delegates.
        .package(path: "../CmuxSidebarProviderKit"),
        // SidebarDragAutoScrollController drives edge auto-scroll during a drag.
        .package(path: "../CmuxAppKitSupportUI"),
        // DEBUG-only drag-trace logging for the external-drop delegate.
        .package(path: "../CMUXDebugLog"),
        // UpdateStateModel backs the sidebar footer's update pill.
        .package(path: "../CmuxUpdater"),
        // UpdatePill/UpdateActionsHost render the sidebar footer's update pill.
        .package(path: "../CmuxUpdaterUI"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarUI",
            dependencies: [
                .product(name: "CmuxSidebar", package: "CmuxSidebar"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxExtensionKit", package: "CmuxExtensionKit"),
                .product(name: "CmuxSidebarProviderKit", package: "CmuxSidebarProviderKit"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxUpdater", package: "CmuxUpdater"),
                .product(name: "CmuxUpdaterUI", package: "CmuxUpdaterUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarUITests",
            dependencies: [
                "CmuxSidebarUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
