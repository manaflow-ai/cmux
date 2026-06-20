// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTestSupport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTestSupport",
            targets: ["CmuxTestSupport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxTestSupport",
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
            name: "CmuxTestSupportTests",
            dependencies: ["CmuxTestSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
