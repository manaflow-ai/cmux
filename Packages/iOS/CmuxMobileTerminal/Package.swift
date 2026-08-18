// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileTerminal",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "CmuxMobileTerminal",
            targets: ["CmuxMobileTerminal"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminalKit"),
    ],
    targets: [
        // The same libghostty the Mac links; iOS feeds raw PTY bytes straight
        // into ghostty_surface_* so the phone runs the identical terminal core.
        //
        // Named distinctly from CmuxTerminalCore's binary target for the same
        // xcframework: SwiftPM requires target names to be unique across the whole
        // package graph, and any workspace that resolves the iOS and macOS packages
        // together sees both. CmuxTerminalCore cannot be reused here - it is a macOS
        // package - so the one xcframework is referenced twice under distinct target
        // names. The module imported in source is still GhosttyKit; that name comes
        // from the xcframework, not from this target.
        .binaryTarget(
            name: "GhosttyKitMobile",
            path: "../../../GhosttyKit.xcframework"
        ),
        .target(
            name: "CmuxMobileTerminal",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxMobileDiagnostics",
                "CmuxMobileSupport",
                "CmuxMobileTerminalKit",
                "GhosttyKitMobile",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxMobileTerminalTests",
            dependencies: ["CmuxMobileTerminal"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            // GhosttyKit's static lib carries C++ objects (glslang); the
            // standalone xctest bundle must link the C++ runtime itself.
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
