// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSession",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSession",
            targets: ["CmuxSession"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxSession",
            dependencies: [
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSessionTests",
            dependencies: ["CmuxSession"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
