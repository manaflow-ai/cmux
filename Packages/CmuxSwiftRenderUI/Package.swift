// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSwiftRenderUI",
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
    ],
    targets: [
        .target(
            name: "CmuxSwiftRenderUI",
            dependencies: [
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ]
        ),
    ]
)
