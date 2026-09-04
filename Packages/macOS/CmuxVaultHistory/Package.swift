// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxVaultHistory",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxVaultHistory",
            targets: ["CmuxVaultHistory"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxVaultHistory",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxVaultHistoryTests",
            dependencies: ["CmuxVaultHistory"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
