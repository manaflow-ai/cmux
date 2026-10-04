// swift-tools-version: 6.0

import PackageDescription

// The one libghostty binary for cmux-next: GhosttyNextKit from
// manaflow-ai/ghostty-next (plans/cmux-next/ghostty-next-switch.md). The Mac
// app (CmuxNextTerminal) and the iOS app (CmuxiOSTerminal) both depend on
// this product, so the workspace resolves exactly one binary target of that
// name. Flavor apple-v6: macOS arm64 + x86_64, iOS, iOS simulator.
//
// A pin change is one reviewed commit that changes the URL and the checksum
// together (the zip's sha256, also in the release's SHA256SUMS). Never pin
// a7c40619a or 3e9dfca98 (apple-v6 without the lib prefix on the macOS
// archive), ios-v1 (module GhosttyKit) or ios-v2 (draws black).
let package = Package(
    name: "CmuxGhosttyKit",
    products: [
        .library(
            name: "CmuxGhosttyKit",
            targets: ["GhosttyNextKit"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyNextKit",
            url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-24a0db5d6efd847f6728e561321c3b152ce5c5d0-apple-v6/GhosttyNextKit.xcframework.zip",
            checksum: "618a1014561b3ae1371ee56650fbfd9f82ca9dc4b08878d739a2657c68a3ffdc"
        ),
    ]
)
