// swift-tools-version: 6.0

import PackageDescription

// WebRTC between a user's devices (plans/cmux-next/ios-rtc.md section 3). CmuxRTCSignal is the
// Foundation-only signaling and ICE-server client for the backend's `rtc.*` frames; CmuxRTCLink
// wraps libwebrtc: one peer connection with perfect negotiation, data channels as byte streams with
// backpressure, JSON-line channels, and video tracks. Shared by the iOS app and the Mac host.
let package = Package(
    name: "CmuxRTC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxRTCSignal", targets: ["CmuxRTCSignal"]),
        .library(name: "CmuxRTCLink", targets: ["CmuxRTCLink"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "154.0.0"),
    ],
    targets: [
        .target(name: "CmuxRTCSignal", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "CmuxRTCLink",
            dependencies: ["CmuxRTCSignal", .product(name: "WebRTC", package: "WebRTC")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "CmuxRTCSignalTests", dependencies: ["CmuxRTCSignal"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxRTCLinkTests", dependencies: ["CmuxRTCLink"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
