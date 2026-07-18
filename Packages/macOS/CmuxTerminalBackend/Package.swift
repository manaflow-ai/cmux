// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalBackend",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalBackend",
            targets: ["CmuxTerminalBackend"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTerminalBackend",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedLibrary("bsm"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalBackendTests",
            dependencies: ["CmuxTerminalBackend"]
        ),
    ]
)
