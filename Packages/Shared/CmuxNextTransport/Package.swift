// swift-tools-version:6.0
import PackageDescription

// CmuxNextTransport: the from-scratch transport proven in the cmux-lite
// program (manaflow-ai/cmuxterm-hq#309-#317) — admission/grants/lanes on
// QUIC via the iroh fork, single ReconnectOwner, zero-gap relay credential
// rotation, self-minting BrokerCredentialClient. Vendored verbatim from
// cmux-lite/CmuxTransport at graduation (P4); the lab remains the harness.
// Consumed behind the dev-only next-transport gate until E1 clears.
let package = Package(
    name: "CmuxNextTransport",
    // iOS 18 matches CmuxIrohTransport, which the bridge target links; every
    // app consumer of this package already requires it.
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "CmuxNextTransport", targets: ["CmuxNextTransport"]),
        .library(name: "CmuxNextTransportBridge", targets: ["CmuxNextTransportBridge"]),
    ],
    dependencies: [
        // Fork-lineage release WITH the credential-handoff machinery, and
        // the same exact pin CmuxIrohTransport uses (SwiftPM unifies one
        // iroh-ffi per graph). v1.0.2-cmux.7's artifact is fork-built —
        // verified by binary strings; only the cmux-lite BRANCH consumed
        // stock upstream (manaflow-ai/iroh-ffi#10). The lab pins
        // v1.0.2-cmux.8 (same sources, rebuilt artifact).
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.0.2-cmux.7"),
        .package(path: "../CmuxIrohTransport"),
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxNextTransport",
            dependencies: [.product(name: "IrohLib", package: "iroh-ffi")],
            path: "Sources/CmuxTransport"),
        // Graduation lane bridge: adapters that let the legacy application
        // router and byte-transport consumers run unchanged over this
        // transport's raw streams. Kept out of the core target so the
        // lab-certified transport stays vendored verbatim.
        .target(
            name: "CmuxNextTransportBridge",
            dependencies: [
                "CmuxNextTransport",
                .product(name: "CmuxIrohTransport", package: "CmuxIrohTransport"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            path: "Sources/CmuxTransportBridge"),
        .testTarget(
            name: "CmuxNextTransportTests",
            dependencies: ["CmuxNextTransport"],
            path: "Tests/CmuxTransportTests"),
        .testTarget(
            name: "CmuxNextTransportBridgeTests",
            dependencies: [
                "CmuxNextTransport",
                "CmuxNextTransportBridge",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            path: "Tests/CmuxTransportBridgeTests"),
    ]
)
