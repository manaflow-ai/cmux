// swift-tools-version: 6.2

import PackageDescription

// RFB (VNC) over a WebRTC data channel: the viewer's RFBTransport, the host
// bridge from the channel to a VNC server (macOS Screen Sharing), pairing
// links, and `cmux-vnc-host`. Signaling and ICE come from the cmux-vnc-signal
// Worker (experiments/cmux-vnc-ios/signal). libwebrtc is the build the CmuxLink
// WebRTC lanes pin (stasel/WebRTC M154).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxVNCWebRTC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxVNCWebRTC", targets: ["CmuxVNCWebRTC"]),
        .executable(name: "cmux-vnc-host", targets: ["cmux-vnc-host"]),
    ],
    dependencies: [
        .package(path: "../CmuxVNC"),
        // The portable Mutex the shared session state lives in.
        .package(path: "../CmuxSafeConcurrency"),
        // cmux-vnc-host's blockingCall.
        .package(path: "../CmuxThreading"),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/154.0.0/WebRTC-M154.xcframework.zip",
            checksum: "a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16"
        ),
        .target(name: "CmuxVNCWebRTC", dependencies: ["WebRTC", .product(name: "CmuxVNC", package: "CmuxVNC"),
                                                      .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "cmux-vnc-host", dependencies: ["CmuxVNCWebRTC", .product(name: "CmuxVNC", package: "CmuxVNC"),
                                                                .product(name: "CmuxThreading", package: "CmuxThreading")],
                          swiftSettings: swiftSettings),
        .testTarget(name: "CmuxVNCWebRTCTests",
                    dependencies: ["CmuxVNCWebRTC", "WebRTC", .product(name: "CmuxVNC", package: "CmuxVNC"),
                                   .product(name: "CmuxVNCDemoServer", package: "CmuxVNC")],
                    swiftSettings: swiftSettings),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxVNCWebRTC",
            "CmuxVNCWebRTCTests",
            "cmux-vnc-host",
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
