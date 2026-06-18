// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCore",
            targets: ["CmuxCore"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxCore",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCoreTests",
            dependencies: ["CmuxCore"]
        ),
    ]
)
