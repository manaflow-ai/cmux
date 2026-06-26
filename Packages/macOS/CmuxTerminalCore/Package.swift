// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalCore",
            targets: ["CmuxTerminalCore"]
        ),
        // Re-vends the GhosttyKit binaryTarget so the CmuxTerminal runtime
        // package can implement seam protocols whose signatures use ghostty C
        // types, without declaring a duplicate binary target for the one
        // xcframework.
        .library(
            name: "CmuxGhosttyKit",
            targets: ["GhosttyKit"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CmuxCore"),
    ],
    targets: [
        // The same libghostty the app links; the terminal core's value types and
        // FFI seam speak the ghostty C types directly so no translation layer
        // can drift from the runtime.
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../../GhosttyKit.xcframework"
        ),
        .target(
            name: "CmuxTerminalCore",
            dependencies: [
                "GhosttyKit",
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxCore", package: "CmuxCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        // Test-only stand-in for the @_silgen_name libghostty symbol bound by
        // GhosttyRuntimeCInterop: SwiftPM cannot link the GhosttyKit macOS
        // archive (its binary lacks the lib prefix), so the test runner
        // satisfies the link with a stub. The app links the real GhosttyKit.
        .target(
            name: "GhosttyRuntimeTestStubs",
            path: "Tests/GhosttyRuntimeTestStubs"
        ),
        .testTarget(
            name: "CmuxTerminalCoreTests",
            dependencies: [
                "CmuxTerminalCore",
                "GhosttyRuntimeTestStubs",
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
