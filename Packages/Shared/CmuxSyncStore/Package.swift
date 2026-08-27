// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSyncStore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSyncStore",
            targets: ["CmuxSyncStore"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(path: "../../iOS/CmuxMobilePairedMac"),
        .package(path: "../../iOS/CmuxMobileShellModel"),
    ],
    targets: [
        .target(
            name: "CmuxSyncStore",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobilePairedMac",
                "CmuxMobileShellModel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSyncStoreTests",
            dependencies: ["CmuxSyncStore", "CmuxMobilePairedMac", "CMUXMobileCore", "CmuxMobileShellModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
