// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxPeerTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxPeerTransport",
            targets: ["CmuxPeerTransport"]
        ),
        .library(
            name: "CmuxPeerTransportBridge",
            targets: ["CmuxPeerTransportBridge"]
        ),
    ],
    dependencies: [
        // Same exact pin as CmuxIrohTransport: SwiftPM allows one iroh-ffi per
        // graph, and the fork artifact ships make-before-break relay
        // credential handoff (insertRelay-alone rotation), which v2 relies on.
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.0.2-cmux.7"
        ),
        .package(path: "../CmuxIrohTransport"),
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxPeerTransport",
            dependencies: [
                .product(name: "IrohLib", package: "iroh-ffi")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .target(
            name: "CmuxPeerTransportBridge",
            dependencies: [
                "CmuxPeerTransport",
                "CmuxIrohTransport",
                "CMUXMobileCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxPeerTransportTests",
            dependencies: ["CmuxPeerTransport"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "CmuxPeerTransportBridgeTests",
            dependencies: ["CmuxPeerTransportBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
