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
        .package(path: "../../Shared/CmuxAuthRuntime"),
        .package(path: "../CmuxAgentChatUI"),
        .package(path: "../CmuxAgentGUIUI"),
        .package(path: "../CmuxMobileBrowser"),
        .package(path: "../CmuxMobileCamera"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobilePairedMac"),
        .package(path: "../CmuxMobileShell"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminal"),
        .package(path: "../CmuxMobileTerminalKit"),
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
                "CmuxAgentGUIUI",
                "CmuxMobileBrowser",
                "CmuxMobileCamera",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
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
                "CmuxAgentChat",
                "CmuxAuthRuntime",
                "CmuxMobilePairedMac",
                "CmuxMobileShellUI",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileTerminal",
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
