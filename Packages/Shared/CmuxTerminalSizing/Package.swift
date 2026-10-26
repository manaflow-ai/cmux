// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CmuxTerminalSizing",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxTerminalSizing", targets: ["CmuxTerminalSizing"])],
    dependencies: [.package(path: "../CmuxFuzzSupport")],
    targets: [
        .target(name: "CmuxTerminalSizing"),
        .testTarget(name: "CmuxTerminalSizingTests", dependencies: ["CmuxTerminalSizing", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")])
    ],
    swiftLanguageModes: [.v6]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxTerminalSizing",
            "CmuxTerminalSizingTests",
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
