// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSudoBroker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxSudoBroker", targets: ["CmuxSudoBroker"]),
    ],
    targets: [
        .target(
            name: "CmuxSudoBroker",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSudoBrokerTests",
            dependencies: ["CmuxSudoBroker"]
        ),
    ]
)
