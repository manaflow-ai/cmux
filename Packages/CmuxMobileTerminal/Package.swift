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
        .package(path: "../CMUXMobileCore"),
        .package(path: "../CmuxMobileDiagnostics"),
        .package(path: "../CmuxMobileGhosttyEngine"),
        .package(path: "../CmuxMobileTerminalKit"),
    ],
    targets: [
        .target(
            name: "CmuxMobileTerminal",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobileDiagnostics",
                // Owns the GhosttyKit binaryTarget and every libghostty call;
                // this host layer only talks to its engine/session/registry.
                "CmuxMobileGhosttyEngine",
                "CmuxMobileTerminalKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
