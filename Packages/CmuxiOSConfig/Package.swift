// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxiOSConfig",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxiOSConfig",
            targets: ["CmuxiOSConfig"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXAuthCore"),
    ],
    targets: [
        .target(
            name: "CmuxiOSConfig",
            dependencies: [
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxiOSConfigTests",
            dependencies: ["CmuxiOSConfig"]
        ),
    ]
)
