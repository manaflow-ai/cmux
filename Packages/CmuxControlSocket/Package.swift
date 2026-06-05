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
        .package(path: "../CmuxSocketControl"),
    ],
    targets: [
        .target(
            name: "CmuxControlSocket",
            dependencies: [
                .product(name: "CmuxSocketControl", package: "CmuxSocketControl"),
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
                .product(name: "CmuxSocketControl", package: "CmuxSocketControl"),
            ]
        ),
    ]
)
