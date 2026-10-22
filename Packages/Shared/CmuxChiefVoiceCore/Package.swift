// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The Chief call / voice-note flow behind the iPhone Action Button
// (plans/cmux-next/ios-action-button-DESIGN.md): the request type, the call
// coordinator state machine, the protocol seams the iOS adapters implement
// (recorder, transcriber, mic permission, delivery) and the on-disk voice-note
// outbox. No UIKit or AVFoundation, so it tests headless with `swift test`.
let package = Package(
    name: "CmuxChiefVoiceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxChiefVoiceCore", targets: ["CmuxChiefVoiceCore"]),
    ],
    targets: [
        .target(
            name: "CmuxChiefVoiceCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxChiefVoiceCoreTests",
            dependencies: ["CmuxChiefVoiceCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#if os(Linux)
// CryptoKit is Apple-only: a build for Linux takes the same API from swift-crypto (`import Crypto`). Only
// the Linux package jobs (swift-packages-linux.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple
// platform on a Linux host (the fleet) keeps CryptoKit and resolves no remote package, so this package
// has no Package.resolved (scripts/check-package-resolved-policy.py skips this block).
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    package.targets.first { $0.name == "CmuxChiefVoiceCore" }?.dependencies.append(
        .product(name: "Crypto", package: "swift-crypto")
    )
}
#endif
