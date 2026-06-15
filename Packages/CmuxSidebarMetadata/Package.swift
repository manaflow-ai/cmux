// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebarMetadata",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebarMetadata",
            targets: ["CmuxSidebarMetadata"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSidebar"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarMetadata",
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
            name: "CmuxSidebarMetadataTests",
            dependencies: ["CmuxSidebarMetadata"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
