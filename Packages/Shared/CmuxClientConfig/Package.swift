// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxClientConfig",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxClientConfig",
            targets: ["CmuxClientConfig"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxClientConfig",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxClientConfigTests",
            dependencies: ["CmuxClientConfig"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
