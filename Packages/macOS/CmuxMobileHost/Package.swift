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
        .package(path: "../../Shared/CmuxArtifactCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobileHost",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxArtifactCore", package: "CmuxArtifactCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileHostTests",
            dependencies: ["CmuxMobileHost"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
