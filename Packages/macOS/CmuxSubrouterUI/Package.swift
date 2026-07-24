// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSubrouterUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSubrouterUI",
            targets: ["CmuxSubrouterUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSubrouter"),
        .package(path: "../CmuxAppKitSupportUI"),
    ],
    targets: [
        .target(
            name: "CmuxSubrouterUI",
            dependencies: [
                .product(name: "CmuxSubrouter", package: "CmuxSubrouter"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
