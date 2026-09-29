// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFileSearch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFileSearch",
            targets: ["CmuxFileSearch"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFileSearch",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFileSearchTests",
            dependencies: ["CmuxFileSearch"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
