// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// cmux Computer Use (docs/computer-use-helper.md): the one signed process that holds the
// Accessibility and Screen Recording grants, started by the cmux-tui daemon
// with macOS responsibility disclaimed, and its two workers.
//
//   CmuxHelperWire           -> JSON lines, process stamps, peer checks (no AppKit)
//   CmuxHelperHost           -> Wire, AppKit (supervisor link, worker supervision, permissions, app socket)
//   CmuxHelperComputerUse    -> Wire, CmuxCuaHelperCore (the Computer Use worker: upstream Cua Driver)
//   CmuxHelperScreenSharing  -> Wire, CmuxDeviceHub, CmuxVNCWebRTC, AppKit (this Mac's device, sessions, banner)
//   cmux-helper-host              -> all of them (the executable in "cmux Helper Host.app")
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxHelperHost",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-helper-host", targets: ["cmux-helper-host"]),
        .library(name: "CmuxHelperWire", targets: ["CmuxHelperWire"]),
    ],
    dependencies: [
        .package(path: "../CmuxComputerUseHelper"),
        .package(path: "../../Shared/CmuxDeviceHub"),
        .package(path: "../../Shared/CmuxVNCWebRTC"),
    ],
    targets: [
        .target(name: "CmuxHelperWire", swiftSettings: swiftSettings),
        .target(
            name: "CmuxHelperHost",
            dependencies: ["CmuxHelperWire", .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub")],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("Security")]
        ),
        .target(
            name: "CmuxHelperComputerUse",
            dependencies: ["CmuxHelperWire", .product(name: "CmuxCuaHelperCore", package: "CmuxComputerUseHelper")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxHelperScreenSharing",
            dependencies: [
                "CmuxHelperWire",
                .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
                .product(name: "CmuxVNCWebRTC", package: "CmuxVNCWebRTC"),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "cmux-helper-host",
            dependencies: ["CmuxHelperWire", "CmuxHelperHost", "CmuxHelperComputerUse", "CmuxHelperScreenSharing"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            // Process-level: the executable is a dependency so `swift test`
            // builds it; the tests drive a real host over its sockets.
            name: "CmuxHelperHostProcessTests",
            dependencies: [
                "cmux-helper-host", "CmuxHelperWire", "CmuxHelperHost", "CmuxHelperScreenSharing",
                .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
