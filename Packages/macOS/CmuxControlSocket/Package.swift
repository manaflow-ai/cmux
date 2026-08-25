// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxControlSocket",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxControlSocket",
            targets: ["CmuxControlSocket"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxBrowser"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxControlSocketAtomicsC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CmuxControlSocket",
            dependencies: [
                .product(name: "CmuxBrowser", package: "CmuxBrowser"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                "CmuxControlSocketAtomicsC",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxControlSocketTests",
            dependencies: [
                "CmuxControlSocket",
                .product(name: "CmuxBrowser", package: "CmuxBrowser"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ]
        ),
    ]
)
