// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalFrontend",
            targets: ["CmuxTerminalFrontend"]
        ),
        .library(
            name: "CmuxTerminal",
            targets: ["CmuxTerminal"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CMUXAgentLaunch"),
        .package(path: "../CmuxTerminalRenderTransport"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalFrontend",
            dependencies: [
                .product(name: "CmuxTerminalDomain", package: "CmuxTerminalCore"),
                .product(
                    name: "CmuxTerminalRenderCompositor",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRenderProtocol",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRenderTransport",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxTerminal",
            dependencies: [
                .product(name: "CmuxTerminalDomain", package: "CmuxTerminalCore"),
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        // Test-only stand-in for the @_silgen_name libghostty symbol bound by
        // CmuxTerminalCore's GhosttyRuntimeCInterop: SwiftPM cannot link the
        // GhosttyKit macOS archive (its binary lacks the lib prefix), so the
        // test runner satisfies the link with a stub. The app links the real
        // GhosttyKit.
        .target(
            name: "GhosttyRuntimeTestStubs",
            path: "Tests/GhosttyRuntimeTestStubs"
        ),
        .testTarget(
            name: "CmuxTerminalFrontendTests",
            dependencies: [
                "CmuxTerminalFrontend",
                .product(
                    name: "CmuxTerminalRenderCompositor",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRenderProtocol",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRenderTransport",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalTests",
            dependencies: [
                "CmuxTerminal",
                "GhosttyRuntimeTestStubs",
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
