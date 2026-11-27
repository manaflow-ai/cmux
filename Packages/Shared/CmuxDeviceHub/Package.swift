// swift-tools-version: 6.2

import Foundation
import PackageDescription

// CmuxDeviceHub: a cmux app's side of the device hub (docs/device-hub/PROTOCOL.md):
// this device's identity (Secure Enclave keys; software keys in the iOS
// simulator, which has no enclave), the device-signed HTTP client, the User DO
// socket, relay secret sealing and the `DeviceHub` model a UI reads. No UI.
//
// The iOS app's Screen Sharing viewer uses it. It began as a copy of the macOS
// app's CmuxNextDevices target (Packages/macOS/CmuxNext), which keeps its own
// copy until it moves onto this package.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxDeviceHub",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxDeviceHub", targets: ["CmuxDeviceHub"]),
    ],
    dependencies: [
        .package(path: "../CmuxEgress"),
    ],
    targets: [
        .plugin(name: "DeviceGlyphGeneratorPlugin", capability: .buildTool(), path: "Plugins/DeviceGlyphGeneratorPlugin"),
        .target(name: "CmuxDeviceHub", dependencies: [.product(name: "CmuxEgress", package: "CmuxEgress")], swiftSettings: swiftSettings, plugins: ["DeviceGlyphGeneratorPlugin"]),
        .testTarget(name: "CmuxDeviceHubTests", dependencies: ["CmuxDeviceHub"], swiftSettings: swiftSettings),
    ]
)

#if os(Linux)
// CryptoKit is Apple-only: a build for Linux takes the same API from swift-crypto (`import Crypto`). Only
// the Linux package jobs (swift-linux-packages.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple
// platform on a Linux host (the fleet) keeps CryptoKit and resolves no remote package, so this package
// has no Package.resolved (scripts/check-package-resolved-policy.py skips this block). The Keychain and
// Secure Enclave code is behind `#if canImport(Security)`.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for target in package.targets where target.name == "CmuxDeviceHub" || target.name == "CmuxDeviceHubTests" {
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    }
}
#endif
