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
                "CmuxMobileDiagnostics",
                "CmuxMobileSupport",
                "CmuxMobileTerminalKit",
                "GhosttyKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Byte-level integration tests for the hardware-keyboard capture path
        // (`TerminalInputTextView.pressesBegan` → resolver → encoder → send
        // sink). UIKit-dependent, so this target runs on an iOS Simulator
        // destination, not via `swift test`.
        .testTarget(
            name: "CmuxMobileTerminalTests",
            dependencies: [
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            // The test bundle transitively links the GhosttyKit binary target
            // (`libghostty`, C++), so it must pull in the C++ runtime the app
            // target links implicitly; without this the C++ stdlib symbols
            // (std::runtime_error, std::length_error, …) are undefined at link.
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
