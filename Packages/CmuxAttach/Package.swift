// swift-tools-version: 6.0
import PackageDescription

// CmuxAttach holds the portable, dependency-free core of the bare-terminal
// attach feature: the wire frame codec, terminal-size arbitration, and attach
// handshake parsing. It links no AppKit, no libghostty, and no app types, so it
// builds and unit-tests standalone with `swift test` even when the full app
// target cannot be built locally. Both the host (cmux app) and the client
// (`cmux attach` CLI) depend on this package so the wire format has exactly one
// definition and cannot drift between the two ends.
let package = Package(
    name: "CmuxAttach",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CmuxAttach", targets: ["CmuxAttach"]),
    ],
    targets: [
        .target(name: "CmuxAttach"),
        .testTarget(name: "CmuxAttachTests", dependencies: ["CmuxAttach"]),
    ]
)
