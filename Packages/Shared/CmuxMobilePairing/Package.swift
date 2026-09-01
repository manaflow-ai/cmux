// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobilePairing",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobilePairing",
            targets: ["CmuxMobilePairing"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobilePairing",
            dependencies: ["CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobilePairingTests",
            dependencies: ["CmuxMobilePairing", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
