// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCLISocketAuth",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCLISocketAuth",
            targets: ["CmuxCLISocketAuth"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxCLISocketAuth",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCLISocketAuthTests",
            dependencies: ["CmuxCLISocketAuth"]
        ),
    ]
)
