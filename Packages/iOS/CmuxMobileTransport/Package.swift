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
    ],
    targets: [
        .binaryTarget(
            name: "CmuxIrohFFI",
            path: "../../../CmuxIrohFFI.xcframework"
        ),
        .target(
            name: "CmuxIrohC",
            dependencies: ["CmuxIrohFFI"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CmuxMobileTransport",
            dependencies: ["CMUXMobileCore", "CmuxIrohC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
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
