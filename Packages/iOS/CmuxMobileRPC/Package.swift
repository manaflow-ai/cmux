// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileRPC",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileRPC",
            targets: ["CmuxMobileRPC"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTerminalSizing"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileRPC",
            dependencies: [
                "CMUXMobileCore",
                "CmuxTerminalSizing",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileRPCTests",
            dependencies: [
                "CmuxMobileRPC",
                "CMUXMobileCore",
                "CmuxMobileShellModel",
                "CmuxTerminalSizing",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
