// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobilePairedMac",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobilePairedMac",
            targets: ["CmuxMobilePairedMac"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobilePairedMac",
            dependencies: [
                "CMUXMobileCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobilePairedMacTests",
            dependencies: ["CmuxMobilePairedMac"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
