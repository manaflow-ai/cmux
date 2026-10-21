// swift-tools-version: 6.0

import PackageDescription

// Linux has no CryptoKit; swift-crypto provides the same API there.
var packageDependencies: [Package.Dependency] = []
var cryptoDependencies: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
cryptoDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

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
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CmuxChiefVoiceCore",
            dependencies: cryptoDependencies,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxChiefVoiceCoreTests",
            dependencies: ["CmuxChiefVoiceCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
