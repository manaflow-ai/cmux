// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxPanes",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxPanes",
            targets: ["CmuxPanes"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxPanes",
            dependencies: [
                "CMUXMobileCore",
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPanesTests",
            dependencies: ["CmuxPanes", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
