// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileShellUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "CmuxMobileShellUI",
            targets: ["CmuxMobileShellUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../CmuxAgentChatUI"),
        .package(path: "../../Shared/CmuxAuthRuntime"),
        .package(path: "../CmuxMobileBrowser"),
        .package(path: "../CmuxMobileBrowserStream"),
        .package(path: "../CmuxMobileCamera"),
        .package(path: "../CmuxMobileChanges"),
        .package(path: "../../Shared/CmuxMobileDiagnostics"),
        .package(path: "../../Shared/CmuxMobilePairedMac"),
        .package(path: "../../Shared/CmuxMobileRPC"),
        .package(path: "../../Shared/CmuxMobileShell"),
        .package(path: "../../Shared/CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSimulatorStream"),
        .package(path: "../../Shared/CmuxSimulatorStreamKit"),
        .package(path: "../../Shared/CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminal"),
        .package(path: "../../Shared/CmuxMobileTerminalKit"),
        .package(path: "../CmuxMobileToast"),
        .package(path: "../CmuxMobileWorkspace"),
        .package(path: "../../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "CmuxMobileShellUI",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxAgentChatUI",
                "CmuxAuthRuntime",
                "CmuxMobileBrowser",
                "CmuxMobileBrowserStream",
                "CmuxMobileCamera",
                "CmuxMobileChanges",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileSimulatorStream",
                "CmuxSimulatorStreamKit",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileToast",
                "CmuxMobileWorkspace",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxMobileShellUITests",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAuthRuntime",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShellUI",
                "CmuxAgentChat",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileSimulatorStream",
                "CmuxSimulatorStreamKit",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileToast",
                "CmuxMobileWorkspace",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
