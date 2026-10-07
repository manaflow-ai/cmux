// swift-tools-version: 6.0

import PackageDescription

// The iPhone's client for the cmux.mobile/1 control plane on Durable Objects
// (plans/cmux-next/ios-next/b1-control-do.md): one hibernating WebSocket per
// owner (`/v1/wire/user`, `/v1/wire/host/<host>`), hello negotiation, stream
// subscriptions with revision cursors, reconnect with resume, ops with
// idempotency keys, reads, and WebRTC signaling. Frames are CmuxMobileWire's.
let package = Package(
    name: "CmuxControlPlane",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxControlPlane", targets: ["CmuxControlPlane"])],
    dependencies: [.package(path: "../CmuxMobileWire")],
    targets: [
        .target(name: "CmuxControlPlane", dependencies: ["CmuxMobileWire"]),
        .testTarget(name: "CmuxControlPlaneTests", dependencies: ["CmuxControlPlane", "CmuxMobileWire"]),
    ],
    swiftLanguageModes: [.v6]
)
