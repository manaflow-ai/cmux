// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileIrxControl",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileIrxControl",
            targets: ["CmuxMobileIrxControl"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileIrxControl",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxMobileIrxControlTests",
            dependencies: ["CmuxMobileIrxControl"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
