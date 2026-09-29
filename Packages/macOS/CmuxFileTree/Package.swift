// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFileTree",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFileTree",
            targets: ["CmuxFileTree"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFileTree",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFileTreeTests",
            dependencies: ["CmuxFileTree"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
