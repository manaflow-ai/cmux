// swift-tools-version: 6.0

import PackageDescription

// cmux.mobile/1, the wire between the iPhone, the Durable Objects and the Mac
// (plans/cmux-next/ios-next/a0-rpc.md, schemas/mobile-rpc). JSON frames of the
// control plane (cmux.wire/1 plus hello, read, signal, channel.*), the binary
// stream-plane records, and the message catalog. Pure value types, no I/O;
// terminal output reuses CmuxTerminalStream's terminal-snapshot-v1 frame.
let package = Package(
    name: "CmuxMobileWire",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxMobileWire", targets: ["CmuxMobileWire"])],
    dependencies: [.package(path: "../CmuxTerminalStream")],
    targets: [
        .target(name: "CmuxMobileWire", dependencies: ["CmuxTerminalStream"]),
        .testTarget(name: "CmuxMobileWireTests", dependencies: ["CmuxMobileWire", "CmuxTerminalStream"]),
    ],
    swiftLanguageModes: [.v6]
)
