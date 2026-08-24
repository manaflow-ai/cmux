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
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxNextTransport", targets: ["CmuxNextTransport"])
    ],
    dependencies: [
        // The fork-lineage release with the credential-handoff machinery
        // (v1.0.2-cmux.8); the cmux-lite BRANCH artifact is stock upstream
        // and must never be used here (manaflow-ai/iroh-ffi#10).
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            revision: "17df7b7640377f3e21ef97a8a3349900587edc9a")
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
