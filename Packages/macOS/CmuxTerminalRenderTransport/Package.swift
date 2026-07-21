// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalRenderTransport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalRenderTransport",
            targets: ["CmuxTerminalRenderTransport"]
        ),
    ],
    targets: [
        .target(
            name: "TerminalRenderMachIPC",
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "CmuxTerminalRenderTransport",
            dependencies: ["TerminalRenderMachIPC"],
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
        .testTarget(
            name: "CmuxTerminalRenderTransportTests",
            dependencies: ["CmuxTerminalRenderTransport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
