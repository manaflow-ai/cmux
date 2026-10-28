// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The install principal client (identity spec D5): register this install's
// P-256 public key with a user session, prove the key with a one-time
// challenge, and hold the short-lived install token. Platform neutral (the
// signer and the HTTP transport are injected), so it tests on macOS.
let package = Package(
    name: "CmuxInstallAuthCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxInstallAuthCore", targets: ["CmuxInstallAuthCore"])],
    targets: [
        .target(name: "CmuxInstallAuthCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxInstallAuthCoreTests", dependencies: ["CmuxInstallAuthCore"],
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
    for target in package.targets where ["CmuxInstallAuthCore", "CmuxInstallAuthCoreTests"].contains(target.name) {
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    }
}
#endif

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxInstallAuthCore",
            "CmuxInstallAuthCoreTests",
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
