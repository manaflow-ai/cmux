// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSudoBrokerUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxSudoBrokerUI", targets: ["CmuxSudoBrokerUI"]),
    ],
    dependencies: [
        .package(path: "../CmuxSudoBroker"),
    ],
    targets: [
        .target(
            name: "CmuxSudoBrokerUI",
            dependencies: ["CmuxSudoBroker"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSudoBrokerUITests",
            dependencies: ["CmuxSudoBrokerUI"]
        ),
    ]
)
