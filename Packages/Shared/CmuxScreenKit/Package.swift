// swift-tools-version: 6.2

import PackageDescription

// CmuxScreenKit: see and control a computer's screen from an app.
//
// - CmuxScreenKit (iOS, macOS): `ScreenSession`, one live session to a Mac
//   (a cmux screen stream over WebRTC, RFB over WebRTC, or a direct VNC
//   server), with reconnects, quality, input and live stats.
// - CmuxScreenKitUI (iOS): the opt-in screen UI: `ScreenView` (fitted mode,
//   paging between displays, the single touch input model, keyboard) and
//   `ScreenSessionView` (full-screen chrome whose parts are picked with
//   `ScreenFeatures`), plus `MacShortcutsBar`, `ScreenOrientation` and
//   `PairingScanner`.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "CmuxScreenKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxScreenKit", targets: ["CmuxScreenKit"]),
        .library(name: "CmuxScreenKitUI", targets: ["CmuxScreenKitUI"]),
    ],
    dependencies: [
        // OnceContinuation, the continuation that resumes exactly once (p10-stability-089).
        .package(path: "../CmuxSafeConcurrency"),
        .package(path: "../CmuxVNC"),
        .package(path: "../CmuxVNCWebRTC"),
        // Test-only: the seeded fuzz suites (p10-stability-023).
        .package(path: "../CmuxFuzzSupport"),
    ],
    targets: [
        .target(
            name: "CmuxScreenKit",
            dependencies: [
                .product(name: "CmuxVNC", package: "CmuxVNC"),
                .product(name: "CmuxVNCDemoServer", package: "CmuxVNC"),
                .product(name: "CmuxVNCWebRTC", package: "CmuxVNCWebRTC"),
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(name: "CmuxScreenKitUI", dependencies: ["CmuxScreenKit"], swiftSettings: swiftSettings),
        .testTarget(name: "CmuxScreenKitTests", dependencies: [
            "CmuxScreenKit", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
        ], swiftSettings: swiftSettings),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxScreenKit",
            "CmuxScreenKitTests",
            "CmuxScreenKitUI",
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
