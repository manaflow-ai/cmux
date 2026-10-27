// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The iPhone side of feed pushes (plans/cmux-next/feed.md 7.3), platform
// neutral so it tests with `swift test` on macOS: notification categories and
// their actions, the push payload, the answer each action sends, and the
// `/v1/ops` request bodies for push targets and feed answers.
let package = Package(
    name: "CmuxFeedPushCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxFeedPushCore", targets: ["CmuxFeedPushCore"])],
    targets: [
        .target(name: "CmuxFeedPushCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxFeedPushCoreTests", dependencies: ["CmuxFeedPushCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)

#if os(Linux)
// CryptoKit is Apple-only: a build for Linux takes the same API from swift-crypto (`import Crypto`). Only
// the Linux package jobs (swift-packages-linux.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple
// platform on a Linux host (the fleet) keeps CryptoKit and resolves no remote package, so this package
// has no Package.resolved (scripts/check-package-resolved-policy.py skips this block).
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    package.targets.first { $0.name == "CmuxFeedPushCore" }?.dependencies.append(
        .product(name: "Crypto", package: "swift-crypto")
    )
}
#endif

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxFeedPushCore",
            "CmuxFeedPushCoreTests",
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
