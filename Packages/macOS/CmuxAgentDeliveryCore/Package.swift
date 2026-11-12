// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentDeliveryCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentDeliveryCore",
            targets: ["CmuxAgentDeliveryCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentDeliveryCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentDeliveryCoreTests",
            dependencies: ["CmuxAgentDeliveryCore"]
        ),
    ]
)
