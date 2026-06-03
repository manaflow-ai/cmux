// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDaemonProtocol",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDaemonProtocol",
            targets: ["CmuxDaemonProtocol"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalCore"),
    ],
    targets: [
        .target(
            name: "CmuxDaemonProtocol",
            dependencies: [
                .product(name: "CmuxTerminalCore", package: "CmuxTerminalCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDaemonProtocolTests",
            dependencies: ["CmuxDaemonProtocol"]
        ),
    ]
)
