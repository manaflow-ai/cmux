// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentManifests",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentManifests",
            targets: ["CmuxAgentManifests"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxAgentManifests",
            dependencies: [
                .product(name: "CmuxCore", package: "CmuxCore"),
            ],
            resources: [
                .copy("Resources/agent-detection"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentManifestsTests",
            dependencies: [
                "CmuxAgentManifests",
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ]
        ),
    ]
)
