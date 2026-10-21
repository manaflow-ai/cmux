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
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/154.0.0/WebRTC-M154.xcframework.zip",
            checksum: "a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16"
        ),
        .target(name: "CmuxVNCWebRTC", dependencies: ["WebRTC", .product(name: "CmuxVNC", package: "CmuxVNC")],
                swiftSettings: swiftSettings),
        .executableTarget(name: "cmux-vnc-host", dependencies: ["CmuxVNCWebRTC", .product(name: "CmuxVNC", package: "CmuxVNC")],
                          swiftSettings: swiftSettings),
        .testTarget(name: "CmuxVNCWebRTCTests",
                    dependencies: ["CmuxVNCWebRTC", "WebRTC", .product(name: "CmuxVNC", package: "CmuxVNC"),
                                   .product(name: "CmuxVNCDemoServer", package: "CmuxVNC")],
                    swiftSettings: swiftSettings),
    ]
)
