// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// cmux Remote (docs/cmux-remote.md): the one signed process that holds the
// Accessibility and Screen Recording grants, started by the cmux-tui daemon
// with macOS responsibility disclaimed, and its two workers.
//
//   CmuxRemoteWire           -> JSON lines, process stamps, peer checks (no AppKit)
//   CmuxRemoteHost           -> Wire, AppKit (supervisor link, worker supervision, permissions, app socket)
//   CmuxRemoteComputerUse    -> Wire, CmuxCuaHelperCore (the Computer Use worker: upstream Cua Driver)
//   CmuxRemoteScreenSharing  -> Wire, CmuxDeviceHub, CmuxVNCWebRTC, AppKit (this Mac's device, sessions, banner)
//   cmux-remote              -> all of them (the executable in "cmux Remote.app")
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxRemote",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-remote", targets: ["cmux-remote"]),
        .library(name: "CmuxRemoteWire", targets: ["CmuxRemoteWire"]),
    ],
    dependencies: [
        .package(path: "../CmuxComputerUseHelper"),
        .package(path: "../../Shared/CmuxDeviceHub"),
        .package(path: "../../Shared/CmuxVNCWebRTC"),
    ],
    targets: [
        .target(name: "CmuxRemoteWire", swiftSettings: swiftSettings),
        .target(
            name: "CmuxRemoteHost",
            dependencies: ["CmuxRemoteWire"],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("Security")]
        ),
        .target(
            name: "CmuxRemoteComputerUse",
            dependencies: ["CmuxRemoteWire", .product(name: "CmuxCuaHelperCore", package: "CmuxComputerUseHelper")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxRemoteScreenSharing",
            dependencies: [
                "CmuxRemoteWire",
                .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
                .product(name: "CmuxVNCWebRTC", package: "CmuxVNCWebRTC"),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "cmux-remote",
            dependencies: ["CmuxRemoteWire", "CmuxRemoteHost", "CmuxRemoteComputerUse", "CmuxRemoteScreenSharing"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            // Process-level: the executable is a dependency so `swift test`
            // builds it; the tests drive a real host over its sockets.
            name: "CmuxRemoteProcessTests",
            dependencies: ["cmux-remote", "CmuxRemoteWire"],
            swiftSettings: swiftSettings
        ),
    ]
)
