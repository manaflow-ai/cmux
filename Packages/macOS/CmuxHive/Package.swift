// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxHive",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CmuxHive",
            targets: ["CmuxHive"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxMobilePairedMac"),
        .package(path: "../../Shared/CmuxMobileRPC"),
        .package(path: "../../Shared/CmuxMobileShell"),
        .package(path: "../../Shared/CmuxMobileShellModel"),
        .package(path: "../../Shared/CmuxMobileTerminalKit"),
        .package(path: "../../Shared/CmuxMobileTransport"),
    ],
    targets: [
        .target(
            name: "CmuxHive",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileTerminalKit",
                "CmuxMobileTransport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxHiveTests",
            dependencies: [
                "CmuxHive",
                "CMUXMobileCore",
                "CmuxMobilePairedMac",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
