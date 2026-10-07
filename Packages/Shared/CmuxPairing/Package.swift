// swift-tools-version: 6.0
import PackageDescription

// B6 pairing (plans/cmux-next/ios-next/b6-pairing.md): link key certificates
// signed by the install's Secure Enclave key, the versioned `pair`/`attach`
// link grammar, the `trust:<user>` mirror over the control plane, and the
// trusted-key lookup B4's DirectAuthorizer and B2's DTLS fingerprint check use.
// Shared by the iPhone app and the Mac host (B5).
let package = Package(
    name: "CmuxPairing",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxPairing", targets: ["CmuxPairing"])],
    dependencies: [
        .package(path: "../CmuxControlPlane"),
        .package(path: "../CmuxMobileWire"),
        .package(path: "../CmuxLinkDirect"),
    ],
    targets: [
        .target(
            name: "CmuxPairing",
            dependencies: [
                .product(name: "CmuxControlPlane", package: "CmuxControlPlane"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
            ]
        ),
        .testTarget(
            name: "CmuxPairingTests",
            dependencies: [
                "CmuxPairing",
                .product(name: "CmuxControlPlane", package: "CmuxControlPlane"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
