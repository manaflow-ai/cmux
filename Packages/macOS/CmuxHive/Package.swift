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
        .package(path: "../../iOS/CmuxMobilePairedMac"),
        .package(path: "../../iOS/CmuxMobileRPC"),
        .package(path: "../../iOS/CmuxMobileShell"),
        .package(path: "../../iOS/CmuxMobileShellModel"),
        .package(path: "../../iOS/CmuxMobileTerminalKit"),
        .package(path: "../../iOS/CmuxMobileTransport"),
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
