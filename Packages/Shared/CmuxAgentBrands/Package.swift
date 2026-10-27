// swift-tools-version: 6.2

import Foundation
import PackageDescription

// Brand marks for the coding agents, harnesses and model providers cmux supports.
// The catalog is generated from design/agent-icons by scripts/agent-icons/generate.py;
// the macOS app (CmuxNext) and the iOS app draw the same marks through it.
// CmuxAgentBrands is the platform-neutral model (ids, specs, the resolver, the catalog);
// CmuxAgentBrandsUI draws it (Core Graphics, SwiftUI, AppKit) and re-exports the model.

/// The p10 compile-time safety settings (scripts/cmux-next/stability-settings.json fills this list).
let stabilitySwiftSettings: [SwiftSetting] = []

let packageSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)] + stabilitySwiftSettings

let package = Package(
    name: "CmuxAgentBrands",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxAgentBrands", targets: ["CmuxAgentBrands"]),
        .library(name: "CmuxAgentBrandsUI", targets: ["CmuxAgentBrandsUI"]),
    ],
    targets: [
        .target(
            name: "CmuxAgentBrands",
            swiftSettings: packageSwiftSettings
        ),
        .target(
            name: "CmuxAgentBrandsUI",
            dependencies: ["CmuxAgentBrands"],
            swiftSettings: packageSwiftSettings
        ),
        .testTarget(
            name: "CmuxAgentBrandsTests",
            dependencies: ["CmuxAgentBrands"],
            swiftSettings: packageSwiftSettings
        ),
    ]
)

#if os(Linux)
// Core Graphics, SwiftUI and AppKit are Apple-only: the Linux package jobs (CMUX_SWIFTPM_TARGET_LINUX=1,
// scripts/cmux-next/linux/swift-shared.sh) build the model and its tests, not the drawing target.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.products.removeAll { $0.name == "CmuxAgentBrandsUI" }
    package.targets.removeAll { $0.name == "CmuxAgentBrandsUI" }
}
#endif

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxAgentBrands",
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
