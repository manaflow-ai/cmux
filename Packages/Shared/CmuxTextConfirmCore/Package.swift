// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The client side of the per-user text confirmation level
// (plans/cmux-next/home-messaging.md section 21): levels, the lowering flow
// with a presence-key proof over the owner's exact challenge bytes, and a
// mock owner. Platform neutral: the signer, App Attest and the ops are injected.
let package = Package(
    name: "CmuxTextConfirmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxTextConfirmCore", targets: ["CmuxTextConfirmCore"])],
    targets: [
        .target(name: "CmuxTextConfirmCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxTextConfirmCoreTests", dependencies: ["CmuxTextConfirmCore"],
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
    for target in package.targets where ["CmuxTextConfirmCore", "CmuxTextConfirmCoreTests"].contains(target.name) {
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    }
}
#endif
