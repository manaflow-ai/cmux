// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebar",
            targets: ["CmuxSidebar"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSwiftRender"),
        // CmuxSettings supplies the right-sidebar width-override decode used by
        // SidebarResizerGeometryPolicy.
        .package(path: "../CmuxSettings"),
        // CmuxExtensionKit backs the ExtensionHost/ sidebar-extension host view
        // and browser presenter.
        .package(path: "../CmuxExtensionKit"),
        // CmuxSidebarProviderKit supplies the provider descriptor / provider
        // protocol / localized-text value types the provider-selection resolver
        // enumerates.
        .package(path: "../CmuxSidebarProviderKit"),
        // CmuxExtensionSidebarExamples supplies the bundled preset providers
        // (SidebarExamples) offered in the switcher menu.
        .package(path: "../../../Examples/CmuxExtensionSidebarExamples"),
    ],
    targets: [
        .target(
            name: "CmuxSidebar",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxExtensionKit", package: "CmuxExtensionKit"),
                .product(name: "CmuxSidebarProviderKit", package: "CmuxSidebarProviderKit"),
                .product(name: "CmuxExtensionSidebarExamples", package: "CmuxExtensionSidebarExamples"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarTests",
            dependencies: [
                "CmuxSidebar",
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxSidebarProviderKit", package: "CmuxSidebarProviderKit"),
                .product(name: "CmuxExtensionSidebarExamples", package: "CmuxExtensionSidebarExamples"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
