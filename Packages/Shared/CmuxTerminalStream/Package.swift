// swift-tools-version: 6.0

import PackageDescription

// The viewer side of `terminal-snapshot-v1` (spec/terminal-frames.md,
// plans/cmux-next/ghostty-next.md section 2.1): the terminal sub-header of a
// `terminal_bytes` frame and the per-viewer rules (snapshot first, stale
// generations dropped, offset gaps and digest mismatches resync).
// Platform neutral and renderer free: the result is a list of actions.
let package = Package(
    name: "CmuxTerminalStream",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxTerminalStream", targets: ["CmuxTerminalStream"])],
    targets: [
        .target(name: "CmuxTerminalStream", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxTerminalStreamTests", dependencies: ["CmuxTerminalStream"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
