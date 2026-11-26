// swift-tools-version: 6.0

import PackageDescription

// The Swift half of the egress gate (docs/privacy.md, "Egress gate"): every URLSession, WebSocket task and
// NWConnection the Mac and iPhone apps make for themselves goes through this package, so a host with no
// `connects` row is refused (nightly, dev) or logged (release). The host list is kept equal to docs/privacy.md (a test)
// by tests/test_egress_gate.py, the same source as cmux-tui/crates/cmux-egress/hosts.txt.
let package = Package(
    name: "CmuxEgress",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxEgress", targets: ["CmuxEgress"]),
    ],
    targets: [
        .target(
            name: "CmuxEgress",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxEgressTests",
            dependencies: ["CmuxEgress"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
