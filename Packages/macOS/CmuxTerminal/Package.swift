// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminal",
            targets: ["CmuxTerminal"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxPanes"),
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CMUXAgentLaunch"),
        .package(path: "../CmuxTestSupport"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "CmuxTerminal",
            dependencies: [
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
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
            name: "CmuxTerminalTests",
            dependencies: [
                "CmuxTerminal",
                "GhosttyRuntimeTestStubs",
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
