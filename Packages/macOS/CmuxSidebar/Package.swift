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
    ],
    targets: [
        .target(
            name: "CmuxSidebar",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
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
