// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTmuxControlMode",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTmuxControlMode",
            targets: ["CmuxTmuxControlMode"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
    ],
    targets: [
        .target(
            name: "CmuxTmuxControlMode",
            dependencies: [
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTmuxControlModeTests",
            dependencies: [
                "CmuxTmuxControlMode",
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
