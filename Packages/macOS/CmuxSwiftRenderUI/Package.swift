// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSwiftRenderUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSwiftRenderUI",
            targets: ["CmuxSwiftRenderUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSwiftRender"),
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSwiftRenderUI",
            dependencies: [
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CmuxSwiftRenderUITests",
            dependencies: ["CmuxSwiftRenderUI"]
        ),
        // Dev-only GUI lab for iterating on the reorderable drag interaction
        // without an app build. Run: swift run reorder-lab
        .executableTarget(
            name: "reorder-lab",
            dependencies: ["CmuxSwiftRenderUI"]
        ),
    ]
)
