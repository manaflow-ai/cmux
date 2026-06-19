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
    ],
    targets: [
        .target(
            name: "CmuxSidebarUI",
            dependencies: [
                .product(name: "CmuxSidebar", package: "CmuxSidebar"),
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
