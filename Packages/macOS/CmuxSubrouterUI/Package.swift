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
    ],
    targets: [
        .target(
            name: "CmuxSubrouterUI",
            dependencies: [
                .product(name: "CmuxSubrouter", package: "CmuxSubrouter"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
