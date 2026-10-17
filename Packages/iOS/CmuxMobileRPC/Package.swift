// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileRPC",
    defaultLocalization: "en",
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
        .package(path: "../../Shared/CmuxConversation"),
        .package(path: "../../Shared/CmuxTerminalSizing"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileRPC",
            dependencies: [
                "CMUXMobileCore",
                "CmuxConversation",
                "CmuxTerminalSizing",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
            ],
            resources: [.process("Resources")],
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
                "CmuxConversation",
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
