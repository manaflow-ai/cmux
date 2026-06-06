// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxProcess",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxProcess",
            targets: ["CmuxProcess"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxProcess",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxProcessTests",
            dependencies: ["CmuxProcess"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
