// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAndroidEmulator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAndroidEmulator",
            targets: ["CmuxAndroidEmulator"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxAndroidEmulator",
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
            name: "CmuxAndroidEmulatorTests",
            dependencies: [
                "CmuxAndroidEmulator",
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
