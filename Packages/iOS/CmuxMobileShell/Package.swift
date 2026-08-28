// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileShell",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileShell",
            targets: ["CmuxMobileShell"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../CmuxMobileChanges"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobileBrowserStream"),
        .package(path: "../CmuxMobilePairedMac"),
        .package(path: "../CmuxMobileRPC"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTransport"),
        .package(path: "../../Shared/CmuxRelayTransport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileShell",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxMobileChanges",
                "CmuxMobileDiagnostics",
                "CmuxMobileBrowserStream",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
                "CmuxMobileTransport",
                "CmuxRelayTransport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileShellTests",
            dependencies: [
                "CmuxMobileShell",
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxMobileBrowserStream",
                "CmuxMobileChanges",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShellModel",
                "CmuxMobileTransport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
