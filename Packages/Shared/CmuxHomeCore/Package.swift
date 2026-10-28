// swift-tools-version: 6.2

import PackageDescription

// Platform-neutral Home client core: the conversation model (same shapes as the
// conversation owner's wire contract), the HomeSource protocol every backend
// implements (mock, local daemon, cloud), the confirmed mirror + intent log,
// contact parsing for invites, and search over Home messages. No UIKit/AppKit,
// so it builds and tests on macOS with `swift test` and serves iOS and macOS.
let package = Package(
    name: "CmuxHomeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxHomeCore", targets: ["CmuxHomeCore"]),
    ],
    dependencies: [
        // Agent questions (plans/cmux-next/agent-questions.md): the `question` part's model.
        .package(path: "../CmuxAgentQuestion"),
        // The portable Mutex. The CmuxHomeCore library itself depends on it, for
        // GatedHomeSource's state (Mock/, shipped in the library like MockHomeSource), so every
        // consumer links CmuxSafeConcurrency.
        .package(path: "../CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "CmuxHomeCore",
            dependencies: [
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // One condition-polling wait for every suite (no per-suite yield loops).
        .target(
            name: "CmuxHomeCoreTestSupport",
            path: "Tests/CmuxHomeCoreTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeCoreTests",
            dependencies: ["CmuxHomeCore", "CmuxHomeCoreTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxHomeCore",
            "CmuxHomeCoreTestSupport",
            "CmuxHomeCoreTests",
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
