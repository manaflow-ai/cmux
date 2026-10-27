// swift-tools-version: 6.2

import Foundation
import PackageDescription

// A dependency-free RFB (VNC) client engine shared by the cmux-next Mac app
// (the `remote_view` pane's compatibility source, plans/cmux-next/remote-desktop.md
// section 12) and iOS clients. `CmuxVNCDemoServer` is a small loopback RFB
// server that paints a synthetic desktop, for tests and offline demos.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxVNC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxVNC", targets: ["CmuxVNC"]),
        .library(name: "CmuxVNCDemoServer", targets: ["CmuxVNCDemoServer"]),
    ],
    dependencies: [
        // OnceContinuation, the continuation that resumes exactly once (p10-stability-089), and for the
        // demo server's start (p10-stability-171).
        .package(path: "../CmuxSafeConcurrency"),
        // Test-only: the seeded fuzz suites (p10-stability-023).
        .package(path: "../CmuxFuzzSupport"),
    ],
    targets: [
        .target(name: "CmuxVNC", dependencies: [.product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
                swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CmuxVNCDemoServer", dependencies: [
            "CmuxVNC", .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
        ], swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "CmuxVNCTests", dependencies: [
            "CmuxVNC", "CmuxVNCDemoServer", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
        ], swiftSettings: swiftSettings),
    ]
)

#if os(Linux)
// The Linux package runs (CMUX_SWIFTPM_TARGET_LINUX, scripts/cmux-next/linux/swift-shared.sh) build the
// protocol, decoders and client: Apple SDKs ship the zlib module, so Linux takes it from the system
// library under the same name; CryptoKit and CommonCrypto's ciphers come from swift-crypto. The
// Network.framework transport and the CoreGraphics demo server stay Apple-only behind canImport. A
// build for an Apple platform on a Linux host (the fleet) keeps the graph above, so this block is no
// input of Package.resolved.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    package.targets.append(.systemLibrary(name: "zlib", providers: [.apt(["zlib1g-dev"])]))
    package.targets.first { $0.name == "CmuxVNC" }?.dependencies += [
        "zlib",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
    ]
    package.targets.first { $0.name == "CmuxVNCDemoServer" }?.dependencies.append("zlib")
}
#endif

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxVNC",
            "CmuxVNCDemoServer",
            "CmuxVNCTests",
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
