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
    ]
)
