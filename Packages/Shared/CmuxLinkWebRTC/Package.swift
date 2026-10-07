// swift-tools-version: 6.0
import PackageDescription

// V1 `webrtc` carrier for the CmuxLink seam (plans/cmux-next/ios-next/b2-webrtc.md):
// WebRTC data channels (and media tracks) with P2P ICE and Cloudflare Realtime
// TURN fallback, signaled over the cmux.mobile/1 control plane, with each DTLS
// fingerprint signed by the device or host identity key.
let package = Package(
    name: "CmuxLinkWebRTC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxLinkWebRTC", targets: ["CmuxLinkWebRTC"]),
    ],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxControlPlane"),
        .package(path: "../CmuxMobileWire"),
    ],
    targets: [
        // Google libwebrtc M154, prebuilt by stasel/WebRTC (iOS, iOS simulator,
        // macOS, Mac Catalyst). Pinned by URL and checksum; see b2-webrtc.md
        // section 2 for the mirror plan.
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/154.0.0/WebRTC-M154.xcframework.zip",
            checksum: "a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16"
        ),
        .target(
            name: "CmuxLinkWebRTC",
            dependencies: [
                "WebRTC",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxControlPlane", package: "CmuxControlPlane"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
        .testTarget(
            name: "CmuxLinkWebRTCTests",
            dependencies: [
                "CmuxLinkWebRTC",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
