// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxLiveEval",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxLiveEval",
            targets: ["CmuxLiveEval"]
        ),
        .executable(
            name: "LiveEvalDemo",
            targets: ["LiveEvalDemo"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSwiftRender"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "CmuxLiveEval",
            dependencies: [
                .product(name: "CmuxSwiftRender", package: "CmuxSwiftRender"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "LiveEvalDemo",
            dependencies: ["CmuxLiveEval"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxLiveEvalTests",
            dependencies: ["CmuxLiveEval"]
        ),
    ]
)
