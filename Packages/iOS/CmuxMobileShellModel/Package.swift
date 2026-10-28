// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxMobileShellModel",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileShellModel",
            targets: ["CmuxMobileShellModel"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxTerminalSizing"),
        // OnceContinuation, the continuation that resumes exactly once.
        .package(path: "../../Shared/CmuxSafeConcurrency"),
        // blockingCall for the image reads.
        .package(path: "../../Shared/CmuxThreading"),
    ],
    targets: [
        .target(
            name: "CmuxMobileShellModel",
            dependencies: [
                "CMUXMobileCore",
                "CmuxTerminalSizing",
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                .product(name: "CmuxThreading", package: "CmuxThreading"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileShellModelTests",
            dependencies: ["CmuxMobileShellModel", "CmuxTerminalSizing"],
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
            "CmuxMobileShellModel",
            "CmuxMobileShellModelTests",
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
