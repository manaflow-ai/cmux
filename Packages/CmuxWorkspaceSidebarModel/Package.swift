// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceSidebarModel",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceSidebarModel",
            targets: ["CmuxWorkspaceSidebarModel"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSidebar"),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceSidebarModel",
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
            name: "CmuxWorkspaceSidebarModelTests",
            dependencies: ["CmuxWorkspaceSidebarModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
