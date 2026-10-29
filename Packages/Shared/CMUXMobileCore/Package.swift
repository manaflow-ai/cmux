// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CMUXMobileCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXMobileCore",
            targets: ["CMUXMobileCore"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFuzzSupport"),
        // The portable lock the OSAllocatedUnfairLock stand-in forwards to.
        .package(path: "../CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "CMUXMobileCore",
            dependencies: [.product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CMUXMobileCoreTests",
            dependencies: ["CMUXMobileCore", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
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
            "CMUXMobileCore",
            "CMUXMobileCoreTests",
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
