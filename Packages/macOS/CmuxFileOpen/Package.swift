// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFileOpen",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFileOpen",
            targets: ["CmuxFileOpen"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxTestSupport"),
    ],
    targets: [
        .target(
            name: "CmuxFileOpen",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFileOpenTests",
            dependencies: ["CmuxFileOpen"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
