// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileShellUI",
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
        .package(path: "../CmuxMobileCamera"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobilePairedMac"),
        .package(path: "../CmuxMobileShell"),
        .package(path: "../CmuxMobileShellModel"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminal"),
        .package(path: "../CmuxMobileTerminalKit"),
        .package(path: "../CmuxMobileWorkspace"),
        .package(path: "../CmuxVoice"),
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
                "CmuxMobileCamera",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileWorkspace",
                "CmuxVoice",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxMobileShellUITests",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobilePairedMac",
                "CmuxMobileShellUI",
                "CmuxAgentChat",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileWorkspace",
                "CmuxVoice",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
