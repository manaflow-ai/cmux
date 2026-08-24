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
    platforms: [.macOS(.v14), .iOS("17.5")],
    products: [
        .library(name: "CmuxNextTransport", targets: ["CmuxNextTransport"])
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
            exact: "1.0.2-cmux.7")
    ],
    targets: [
        .target(
            name: "CmuxNextTransport",
            dependencies: [.product(name: "IrohLib", package: "iroh-ffi")],
            path: "Sources/CmuxTransport"),
        .testTarget(
            name: "CmuxNextTransportTests",
            dependencies: ["CmuxNextTransport"],
            path: "Tests/CmuxTransportTests"),
    ]
)
