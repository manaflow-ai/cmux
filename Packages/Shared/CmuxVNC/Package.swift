// swift-tools-version: 6.2

import PackageDescription

// A dependency-free RFB (VNC) client engine shared by the cmux-next Mac app
// (the `remote_view` pane's compatibility source, plans/cmux-next/remote-desktop.md
// section 12) and iOS clients. `CmuxVNCDemoServer` is a small loopback RFB
// server that paints a synthetic desktop, for tests and offline demos.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxVNC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxVNC", targets: ["CmuxVNC"]),
        .library(name: "CmuxVNCDemoServer", targets: ["CmuxVNCDemoServer"]),
    ],
    dependencies: [
        // OnceContinuation, the continuation that resumes exactly once, and for the
        // demo server's start.
        .package(path: "../CmuxSafeConcurrency"),
        // The Mutex the transport keeps its state in.
        .package(path: "../CmuxThreading"),
        // Test-only: the seeded fuzz suites.
        .package(path: "../CmuxFuzzSupport"),
    ],
    targets: [
        .target(name: "CmuxVNC", dependencies: [
            .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            .product(name: "CmuxThreading", package: "CmuxThreading"),
        ], swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CmuxVNCDemoServer", dependencies: [
            "CmuxVNC", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
        ], swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "CmuxVNCTests", dependencies: [
            "CmuxVNC", "CmuxVNCDemoServer", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
            .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
        ], swiftSettings: swiftSettings),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxVNC",
            "CmuxVNCDemoServer",
            "CmuxVNCTests",
        ],
        settings: [
            .strictMemorySafety(),
        ]
    ),
]
for group in stabilitySettingGroups {
    for target in package.targets where group.targets.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + group.settings
    }
}
// END apply-stability-settings.py
