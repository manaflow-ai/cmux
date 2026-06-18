// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalServices",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalServices",
            targets: ["CmuxTerminalServices"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
        .package(path: "../CMUXPasteboardFidelity"),
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalServices",
            dependencies: [
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
                .product(name: "CmuxGhosttyKit", package: "CmuxTerminalCore"),
                .product(name: "CMUXPasteboardFidelity", package: "CMUXPasteboardFidelity"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
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
            name: "CmuxTerminalServicesTests",
            dependencies: [
                "CmuxTerminalServices",
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
