// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalEngine",
            targets: ["CmuxTerminalEngine"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalEngine",
            dependencies: [
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
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
            name: "CmuxTerminalEngineTests",
            dependencies: [
                "CmuxTerminalEngine",
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
