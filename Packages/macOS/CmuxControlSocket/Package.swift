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
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxControlSocket",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
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
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ]
        ),
    ]
)
