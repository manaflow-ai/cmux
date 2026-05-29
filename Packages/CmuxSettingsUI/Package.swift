// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CmuxSettingsUI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CmuxSettingsUI",
            targets: ["CmuxSettingsUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxSettingsUI",
            dependencies: ["CmuxSettings"],
            path: "Sources/CmuxSettingsUI"
        ),
        .testTarget(
            name: "CmuxSettingsUITests",
            dependencies: ["CmuxSettingsUI"],
            path: "Tests/CmuxSettingsUITests"
        ),
    ]
)
