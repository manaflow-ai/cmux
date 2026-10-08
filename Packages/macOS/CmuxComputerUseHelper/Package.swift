// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The cmux Computer Use helper v2 (plans: .cmux-scratch/cua-driver-redo/plan.md,
// phase 1). A separate app owns the macOS Accessibility and Screen Recording
// grants; it loads upstream Cua Driver (MIT, trycua/cua, pinned in
// scripts/cmux-next/cua-driver-sdk.pin.json) in process through its stable C
// ABI, and serves a socket that admits only the acpmux tree the host app
// registered. The library is loaded with dlopen at run time, so this package
// builds and tests without it.
//
//   CCuaDriverABI       -> the vendored upstream header (types only)
//   CmuxCuaHelperCore   -> CCuaDriverABI, Security (admission, control pipe, socket, runtime bridge)
//   cmux-cua-helper     -> CmuxCuaHelperCore (the executable in "cmux Computer Use (dev).app")

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxComputerUseHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cmux-cua-helper", targets: ["cmux-cua-helper"]),
        .library(name: "CmuxCuaHelperCore", targets: ["CmuxCuaHelperCore"]),
    ],
    targets: [
        .target(name: "CCuaDriverABI"),
        .target(
            name: "CmuxCuaHelperCore",
            dependencies: ["CCuaDriverABI"],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("ApplicationServices")]
        ),
        .executableTarget(
            name: "cmux-cua-helper",
            dependencies: ["CmuxCuaHelperCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxCuaHelperCoreTests",
            // The executable is a dependency so `swift test` builds it for the
            // process-level liveness test.
            dependencies: ["CmuxCuaHelperCore", "cmux-cua-helper"],
            swiftSettings: swiftSettings
        ),
    ]
)
