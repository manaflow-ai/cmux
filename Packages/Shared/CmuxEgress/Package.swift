// swift-tools-version: 6.0

import PackageDescription

// CmuxEgress: the Swift side of the egress gate (docs/privacy.md, "Egress gate"). Every URLSession,
// WebSocket and NWConnection the cmux apps open for themselves is made here, so a connection to a
// host docs/privacy.md does not list is refused (dev and nightly) or logged (release) before a
// packet leaves. The Rust side is cmux-tui/crates/cmux-egress; both read the same generated list.
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
