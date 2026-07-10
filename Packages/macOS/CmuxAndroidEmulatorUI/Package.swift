// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAndroidEmulatorUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAndroidEmulatorUI",
            targets: ["CmuxAndroidEmulatorUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxAndroidEmulator"),
    ],
    targets: [
        .target(
            name: "CmuxAndroidEmulatorUI",
            dependencies: [
                .product(name: "CmuxAndroidEmulator", package: "CmuxAndroidEmulator"),
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
    ]
)
