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
        .library(
            name: "CmuxMobileShellReleaseGateSupport",
            targets: ["CmuxMobileShellReleaseGateSupport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(path: "../CmuxAgentChat"),
        .package(path: "../../iOS/CmuxMobileChanges"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../../iOS/CmuxMobileBrowserStream"),
        .package(path: "../CmuxMobilePairedMac"),
        .package(path: "../CmuxMobileRPC"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTransport"),
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
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxMobileShellReleaseGateSupport",
            dependencies: [
                "CmuxMobileShell",
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxMobileRPC",
                "CmuxMobileShellModel",
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
                "CmuxMobileShellReleaseGateSupport",
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
