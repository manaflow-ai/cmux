// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// cmux Computer Use engine: a performance-first macOS Computer Use service
// (plans: .cmux-scratch/cu-fast/DESIGN.md). One long-lived process holds the
// Accessibility and Screen Recording grants and answers MCP tool calls:
//
//   CmuxCUEngine     -> accessibility snapshots (batched attribute reads),
//                       ScreenCaptureKit window capture + JPEG, input
//                       synthesis posted to the target pid, event-driven
//                       settle (AXObserver quiet window), MCP session
//   cmux-cu-service  -> the executable of "cmux CU Engine.app": `serve` (the
//                       engine on a per-user Unix socket), `stdio` (one MCP
//                       session in process) and `mcp` (the agent-side stdio
//                       server: a byte pump to the socket that launches the app)

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxComputerUseEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxCUEngine", targets: ["CmuxCUEngine"]),
        .executable(name: "cmux-cu-service", targets: ["cmux-cu-service"]),
    ],
    targets: [
        .target(
            name: "CmuxCUEngine",
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AppKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .executableTarget(name: "cmux-cu-service", dependencies: ["CmuxCUEngine"], swiftSettings: swiftSettings),
        .testTarget(name: "CmuxCUEngineTests", dependencies: ["CmuxCUEngine"], swiftSettings: swiftSettings),
    ]
)
