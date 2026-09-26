// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileHost",
            targets: ["CmuxMobileHost"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentChat"),
    ],
    targets: [
        .target(
            name: "CmuxMobileHost",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxAgentChat", package: "CmuxAgentChat"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
