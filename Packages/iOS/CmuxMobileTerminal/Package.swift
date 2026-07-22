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
        .binaryTarget(
            name: "GhosttyKit",
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
                "GhosttyKit",
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
