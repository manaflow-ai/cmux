// swift-tools-version: 6.2

import PackageDescription

// App Attest and DeviceCheck for the cmux apps (cx-ds09i): the platform half
// of a device proof. The protocol seams let the Mac free-tier provider and
// the iOS presence-key flow take the real service or a stand-in; the
// product logic that uses a proof lives elsewhere (the relay, the server).
let package = Package(
    name: "CmuxAppAttest",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxAppAttest", targets: ["CmuxAppAttest"])],
    dependencies: [
        // blockingCall for the Keychain calls.
        .package(path: "../CmuxThreading"),
    ],
    targets: [
        .target(name: "CmuxAppAttest", dependencies: [.product(name: "CmuxThreading", package: "CmuxThreading")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxAppAttest",
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
