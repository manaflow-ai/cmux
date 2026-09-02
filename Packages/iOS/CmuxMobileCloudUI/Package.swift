// swift-tools-version: 6.0

import PackageDescription

// UI package for cmux Cloud on the phone: the Cloud section of the Computers
// screen, a machine's terminal catalog, and the terminal screen that feeds
// link bytes into the embedded libghostty view. Depends on the Cloud domain
// package and the terminal view only, never on the shell UI.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxMobileCloudUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileCloudUI", targets: ["CmuxMobileCloudUI"]),
    ],
    dependencies: [
        .package(path: "../CmuxMobileCloud"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileTerminal"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTerminalClient"),
    ],
    targets: [
        .target(
            name: "CmuxMobileCloudUI",
            dependencies: [
                "CmuxMobileCloud",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CMUXMobileCore",
                .product(name: "CmuxTerminalClientKit", package: "CmuxTerminalClient"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxMobileCloudUITests",
            dependencies: ["CmuxMobileCloudUI", "CmuxMobileCloud"],
            swiftSettings: swiftSettings
        ),
    ]
)
