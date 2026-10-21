// swift-tools-version: 6.0

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
