// swift-tools-version: 6.2

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxIrohTransport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIrohTransport",
            targets: ["CmuxIrohTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(path: "../CmuxFuzzSupport"),
        .package(path: "../CmuxSafeConcurrency"),
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.2.0-cmux.1.ios17"
        ),
    ],
    targets: [
        .target(
            name: "CmuxIrohTransport",
            dependencies: [
                "CMUXMobileCore",
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "CmuxIrohTransportTests",
            dependencies: [
                "CmuxIrohTransport",
                "CMUXMobileCore",
                .product(name: "IrohLib", package: "iroh-ffi"),
                .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

#if os(Linux)
// The Linux package runs (CMUX_SWIFTPM_TARGET_LINUX, scripts/cmux-next/linux/swift-shared.sh) build the
// protocol's portable parts: iroh-ffi ships only an Apple xcframework, so its package goes and the files
// that drive it compile under `#if canImport(IrohLib)`; the keychain and dns_sd files likewise. CryptoKit
// comes from swift-crypto (`import Crypto`). A build for an Apple platform on a Linux host (the fleet)
// keeps the graph above, so this block is no input of Package.resolved.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.removeAll { dependency in
        if case .sourceControl = dependency.kind { return true }
        return false
    }
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for target in package.targets {
        target.dependencies.removeAll { dependency in
            if case .productItem(name: "IrohLib", _, _, _) = dependency { return true }
            return false
        }
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
        target.linkerSettings = nil
    }
}
#endif

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxIrohTransport",
            "CmuxIrohTransportTests",
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
