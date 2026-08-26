// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxNestedTopology",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxNestedTopology",
            targets: ["CmuxNestedTopology"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxNestedTopology",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxNestedTopologyTests",
            dependencies: ["CmuxNestedTopology"]
        ),
    ]
)
