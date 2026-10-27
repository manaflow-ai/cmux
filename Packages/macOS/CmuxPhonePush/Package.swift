// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxPhonePush",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxPhonePush", targets: ["CmuxPhonePush"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAuthRuntime"),
    ],
    targets: [
        .target(
            name: "CmuxPhonePush",
            dependencies: ["CmuxAuthRuntime"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPhonePushTests",
            dependencies: ["CmuxPhonePush"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#if os(Linux)
// The Linux package runs (CMUX_SWIFTPM_TARGET_LINUX, scripts/cmux-next/linux/swift-shared.sh) take
// CryptoKit's HPKE and Curve25519 from swift-crypto (`import Crypto`, the same API); the keychain files
// stay Apple-only behind canImport(Security). A build for an Apple platform on a Linux host (the fleet)
// keeps CryptoKit and resolves no remote package, so this block is no input of Package.resolved.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for target in package.targets {
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    }
}
#endif
