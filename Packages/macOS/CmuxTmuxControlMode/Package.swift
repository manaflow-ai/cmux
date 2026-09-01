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
    targets: [
        .target(
            name: "CmuxTmuxControlMode",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTmuxControlModeTests",
            dependencies: ["CmuxTmuxControlMode"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
