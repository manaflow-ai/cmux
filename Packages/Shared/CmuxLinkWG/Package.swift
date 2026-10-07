// swift-tools-version: 6.0
import PackageDescription

// V2 `webrtc-wg` carrier for the CmuxLink seam (plans/cmux-next/ios-next/b3-webrtc-wg.md):
// end-to-end WireGuard per device and host, its datagrams carried by a WebRTC
// unreliable data channel (the `DatagramUnderlay`), with A3's lanes as a small
// reliable-datagram protocol inside the tunnel.
let package = Package(
    name: "CmuxLinkWG",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxLinkWG", targets: ["CmuxLinkWG"]),
        // The in-memory lossy underlay and the conformance harness, for this
        // package's tests and for B2/D2 to run V2 over other underlays.
        .library(name: "CmuxLinkWGTesting", targets: ["CmuxLinkWGTesting"]),
    ],
    dependencies: [
        .package(path: "../CmuxLink"),
    ],
    targets: [
        .target(
            name: "CmuxLinkWG",
            dependencies: [.product(name: "CmuxLink", package: "CmuxLink")]
        ),
        .target(
            name: "CmuxLinkWGTesting",
            dependencies: [
                "CmuxLinkWG",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
            ]
        ),
        .testTarget(
            name: "CmuxLinkWGTests",
            dependencies: [
                "CmuxLinkWG",
                "CmuxLinkWGTesting",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
