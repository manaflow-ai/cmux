// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFleet",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFleet",
            targets: ["CmuxFleet"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFleet",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFleetTests",
            dependencies: [
                "CmuxFleet",
            ]
        ),
    ]
)
