// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxGhosttyConfigLoader",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxGhosttyConfigLoader",
            targets: ["CmuxGhosttyConfigLoader"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxTerminalCore"),
    ],
    targets: [
        .target(
            name: "CmuxGhosttyConfigLoader",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        // Test-only stand-in for the @_silgen_name libghostty symbols bound by
        // CmuxTerminalCore's GhosttyRuntimeCInterop: SwiftPM cannot link the
        // GhosttyKit macOS archive (its binary lacks the lib prefix), so the
        // test runner satisfies the link with a stub. The app links the real
        // GhosttyKit.
        .target(
            name: "GhosttyRuntimeTestStubs",
            path: "Tests/GhosttyRuntimeTestStubs"
        ),
        .testTarget(
            name: "CmuxGhosttyConfigLoaderTests",
            dependencies: [
                "CmuxGhosttyConfigLoader",
                "GhosttyRuntimeTestStubs",
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
