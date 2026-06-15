// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSplitPaneLayout",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSplitPaneLayout",
            targets: ["CmuxSplitPaneLayout"]
        ),
    ],
    dependencies: [
        .package(path: "../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxSplitPaneLayout",
            dependencies: [
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSplitPaneLayoutTests",
            dependencies: ["CmuxSplitPaneLayout"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
