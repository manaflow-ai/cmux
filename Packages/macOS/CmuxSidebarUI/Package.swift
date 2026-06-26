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
        .package(path: "../CmuxFoundation"),
        // ExtensionSidebarBrowserStackDropRow/Planner + CmuxSidebarProviderWorkspaceMove
        // back the extension browser-stack drop delegates.
        .package(path: "../CmuxSidebarProviderKit"),
        // SidebarDragAutoScrollController drives edge auto-scroll during a drag.
        .package(path: "../CmuxAppKitSupportUI"),
        // DEBUG-only drag-trace logging for the external-drop delegate.
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarUI",
            dependencies: [
                .product(name: "CmuxSidebar", package: "CmuxSidebar"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSidebarProviderKit", package: "CmuxSidebarProviderKit"),
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
