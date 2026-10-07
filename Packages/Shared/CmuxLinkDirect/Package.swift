// swift-tools-version: 6.0
import PackageDescription

// V3 `direct` carrier for the CmuxLink seam (plans/cmux-next/ios-next/b4-direct.md):
// dial a Tailscale, WireGuard, LAN or Bonjour address over TCP, mutually
// authenticated with Noise IK pinned to the host and device keys.
let package = Package(
    name: "CmuxLinkDirect",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxLinkDirect", targets: ["CmuxLinkDirect"]),
    ],
    dependencies: [
        .package(path: "../CmuxLink"),
    ],
    targets: [
        .target(
            name: "CmuxLinkDirect",
            dependencies: [.product(name: "CmuxLink", package: "CmuxLink")]
        ),
        .testTarget(
            name: "CmuxLinkDirectTests",
            dependencies: [
                "CmuxLinkDirect",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
