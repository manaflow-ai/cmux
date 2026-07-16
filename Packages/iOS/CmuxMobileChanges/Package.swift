// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileChanges",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileChanges",
            targets: ["CmuxMobileChanges"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileChanges",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileChangesTests",
            dependencies: ["CmuxMobileChanges"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
