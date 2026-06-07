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
        .package(path: "../CMUXMobileCore"),
        .package(path: "../CmuxMobileDiagnostics"),
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
                "CmuxMobileDiagnostics",
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
        .testTarget(
            name: "CmuxMobileShellTests",
            dependencies: [
                "CmuxMobileShell",
                "CMUXMobileCore",
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
