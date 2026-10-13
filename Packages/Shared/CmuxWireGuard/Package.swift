// swift-tools-version: 6.0

import PackageDescription

// In-process WireGuard for the cmux-next Mac and iOS apps.
//
// CmuxWGC is libcmuxwg (wireguard-go on gVisor netstack, built from go/ by
// scripts/build-xcframework.sh): a userspace WireGuard device with its own
// TCP/IP stack, so neither app needs a system VPN or a Network Extension.
// CmuxWireGuard wraps it in Swift (tunnel, listener, socket streams);
// CmuxWireGuardPairing holds the pairing and enrollment wire types both apps
// share and has no binary dependency.
let package = Package(
    name: "CmuxWireGuard",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CmuxWireGuard", targets: ["CmuxWireGuard"]),
        .library(name: "CmuxWireGuardPairing", targets: ["CmuxWireGuardPairing"]),
    ],
    targets: [
        .binaryTarget(
            name: "CmuxWGC",
            path: "Frameworks/CmuxWG.xcframework"
        ),
        .target(
            name: "CmuxWireGuard",
            dependencies: ["CmuxWGC", "CmuxWireGuardPairing"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "CmuxWireGuardPairing",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxWireGuardTests",
            dependencies: ["CmuxWireGuard", "CmuxWireGuardPairing"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxWireGuardPairingTests",
            dependencies: ["CmuxWireGuardPairing"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
