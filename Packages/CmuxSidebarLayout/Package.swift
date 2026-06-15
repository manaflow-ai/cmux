// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebarLayout",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebarLayout",
            targets: ["CmuxSidebarLayout"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSwiftRender"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarLayout",
            dependencies: [
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarLayoutTests",
            dependencies: ["CmuxSidebarLayout"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
