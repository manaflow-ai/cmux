// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSwiftRender",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSwiftRender",
            targets: ["CmuxSwiftRender"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "CmuxSwiftRender",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxSwiftRenderTests",
            dependencies: ["CmuxSwiftRender"],
            // Corpus holds sidebar DSL files (interpreter input, not test code).
            exclude: ["Corpus"]
        ),
    ]
)
