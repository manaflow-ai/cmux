// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSurfaceSelection",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSurfaceSelection",
            targets: ["CmuxSurfaceSelection"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSurfaceSelection",
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
            name: "CmuxSurfaceSelectionTests",
            dependencies: ["CmuxSurfaceSelection"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
