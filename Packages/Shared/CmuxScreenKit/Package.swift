// swift-tools-version: 6.2

import PackageDescription

// CmuxScreenKit: see and control a computer's screen from an app.
//
// - CmuxScreenKit (iOS, macOS): `ScreenSession`, one live session to a Mac
//   (a cmux screen stream over WebRTC, RFB over WebRTC, or a direct VNC
//   server), with reconnects, quality, input and live stats.
// - CmuxScreenKitUI (iOS): the opt-in screen UI: `ScreenView` (fitted mode,
//   paging between displays, direct and trackpad input, keyboard) and
//   `ScreenSessionView` (full-screen chrome whose parts are picked with
//   `ScreenFeatures`), plus `MacShortcutsBar`, `ScreenOrientation` and
//   `PairingScanner`.
//
// The rules (gestures, framing, viewport, cursor cache, reconnect policy) are
// Rust in cmux-rd-core screen_kit, so the tests live in CmuxNext
// (Tests/CmuxScreenKitTests), which links the library.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "CmuxScreenKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxScreenKit", targets: ["CmuxScreenKit"]),
        .library(name: "CmuxScreenKitUI", targets: ["CmuxScreenKitUI"]),
    ],
    dependencies: [
        .package(path: "../CmuxVNC"),
        .package(path: "../CmuxVNCWebRTC"),
        .package(path: "../CmuxSpinner"),
    ],
    targets: [
        // Header-only: the screen viewer core's C ABI (cmux-rd-core
        // screen_kit). The app links the symbols: the Mac through CCmuxAppFFI,
        // iOS through CmuxMobileLinkFFI.
        .target(name: "CCmuxScreenKit"),
        .target(
            name: "CmuxScreenKit",
            dependencies: [
                "CCmuxScreenKit",
                .product(name: "CmuxVNC", package: "CmuxVNC"),
                .product(name: "CmuxVNCDemoServer", package: "CmuxVNC"),
                .product(name: "CmuxVNCWebRTC", package: "CmuxVNCWebRTC"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(name: "CmuxScreenKitUI", dependencies: ["CCmuxScreenKit", "CmuxScreenKit", .product(name: "CmuxSpinner", package: "CmuxSpinner")], swiftSettings: swiftSettings),
    ]
)
