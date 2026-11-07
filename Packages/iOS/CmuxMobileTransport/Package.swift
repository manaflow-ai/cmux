// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileTransport",
            targets: ["CmuxMobileTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxMobileDiagnostics"),
    ],
    targets: [
        .target(
            name: "CmuxMobileTransport",
            dependencies: ["CMUXMobileCore", "CmuxMobileDiagnostics"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileTransportTests",
            dependencies: ["CmuxMobileTransport", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
