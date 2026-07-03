// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSettingsUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSettingsUI",
            targets: ["CmuxSettingsUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxSettingsUI",
            dependencies: [
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ]
        ),
        .testTarget(
            name: "CmuxSettingsUITests",
            dependencies: ["CmuxSettingsUI"]
        ),
    ]
)
