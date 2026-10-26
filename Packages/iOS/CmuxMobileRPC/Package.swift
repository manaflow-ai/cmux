// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileRPC",
    platforms: [
        .iOS(.v17),
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
        // The portable Mutex the timeout cancellation bridge keeps its state in (p10-stability-172).
        .package(path: "../../Shared/CmuxSafeConcurrency"),
        .package(path: "../../Shared/CmuxTerminalSizing"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileRPC",
            dependencies: [
                "CMUXMobileCore",
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
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
