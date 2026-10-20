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
        // CmuxExtensionKit backs the ExtensionHost/ sidebar-extension host view
        // and browser presenter.
        .package(path: "../CmuxExtensionKit"),
    ],
    targets: [
        .target(
            name: "CmuxSidebar",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "CmuxExtensionKit", package: "CmuxExtensionKit"),
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
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
