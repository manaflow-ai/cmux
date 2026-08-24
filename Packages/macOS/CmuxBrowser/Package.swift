// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowser",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowser",
            targets: ["CmuxBrowser"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxBrowser",
            dependencies: [
                "CmuxFoundation",
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserTests",
            dependencies: [
                "CmuxBrowser",
                "CmuxFoundation",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
