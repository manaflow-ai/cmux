// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxMobileSupport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileSupport",
            targets: ["CmuxMobileSupport"]
        ),
    ],
    dependencies: [
        // The portable Mutex the keyboard observers and the dictation audio engine use.
        .package(path: "../../Shared/CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "CmuxMobileSupport",
            dependencies: [.product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileSupportTests",
            dependencies: ["CmuxMobileSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxMobileSupport",
            "CmuxMobileSupportTests",
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
