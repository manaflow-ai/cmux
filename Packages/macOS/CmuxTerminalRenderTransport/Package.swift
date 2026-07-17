// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalRenderTransport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalRenderProtocol",
            targets: ["CmuxTerminalRenderProtocol"]
        ),
        .library(
            name: "CmuxTerminalRenderTransport",
            targets: ["CmuxTerminalRenderTransport"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTerminalRenderProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "TerminalRenderMachIPC",
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedLibrary("bsm"),
            ]
        ),
        .target(
            name: "CmuxTerminalRenderTransport",
            dependencies: [
                "CmuxTerminalRenderProtocol",
                "TerminalRenderMachIPC",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "cmux-terminal-render-test-sender",
            dependencies: [
                "CmuxTerminalRenderProtocol",
                "CmuxTerminalRenderTransport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "TerminalRenderMachIPCTestSupport",
            path: "Tests/TerminalRenderMachIPCTestSupport"
        ),
        .testTarget(
            name: "CmuxTerminalRenderProtocolTests",
            dependencies: ["CmuxTerminalRenderProtocol"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalRenderTransportTests",
            dependencies: [
                "CmuxTerminalRenderProtocol",
                "CmuxTerminalRenderTransport",
                "TerminalRenderMachIPCTestSupport",
                "cmux-terminal-render-test-sender",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
