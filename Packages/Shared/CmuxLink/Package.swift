// swift-tools-version: 6.0
import PackageDescription

// The CmuxLink seam (plans/cmux-next/ios-next/a3-link.md): the one connection
// API every iOS/macOS stream feature uses and every carrier implements.
let package = Package(
    name: "CmuxLink",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxLink", targets: ["CmuxLink"]),
        // Loopback and simulated carriers, a manual clock, and the carrier
        // conformance suite. Carrier lanes run the suite from their tests;
        // feature lanes use the mocks before a real carrier lands.
        .library(name: "CmuxLinkTesting", targets: ["CmuxLinkTesting"]),
        // The WebRTC signaling seam shared by V1 (B2) and V2 (B3): typed
        // `signal` messages, the per-session router and an in-memory relay.
        .library(name: "CmuxLinkSignaling", targets: ["CmuxLinkSignaling"]),
    ],
    targets: [
        .target(name: "CmuxLink"),
        .target(name: "CmuxLinkTesting", dependencies: ["CmuxLink"]),
        .target(name: "CmuxLinkSignaling", dependencies: ["CmuxLink"]),
        .testTarget(
            name: "CmuxLinkTests",
            dependencies: ["CmuxLink", "CmuxLinkTesting"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
