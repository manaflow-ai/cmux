// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSocketControl",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSocketControl",
            targets: ["CmuxSocketControl"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxSocketControl",
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
            name: "CmuxSocketControlTests",
            dependencies: [
                "CmuxSocketControl",
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ]
        ),
    ]
)
