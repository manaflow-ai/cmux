// swift-tools-version: 6.2

import PackageDescription

// CmuxScreenKit: see and control a computer's screen from an app.
//
// - CmuxScreenKit (iOS, macOS): `ScreenSession`, one live session to a Mac
//   (a cmux screen stream over WebRTC, RFB over WebRTC, or a direct VNC
//   server), with reconnects, quality, input and live stats.
// - CmuxScreenKitUI (iOS): the opt-in screen UI: `ScreenView` (fitted mode,
//   paging between displays, the single touch input model, keyboard) and
//   `ScreenSessionView` (full-screen chrome whose parts are picked with
//   `ScreenFeatures`), plus `MacShortcutsBar`, `ScreenOrientation` and
//   `PairingScanner`.
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
    ],
    targets: [
        .target(
            name: "CmuxScreenKit",
            dependencies: [
                .product(name: "CmuxVNC", package: "CmuxVNC"),
                .product(name: "CmuxVNCDemoServer", package: "CmuxVNC"),
                .product(name: "CmuxVNCWebRTC", package: "CmuxVNCWebRTC"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(name: "CmuxScreenKitUI", dependencies: ["CmuxScreenKit"], swiftSettings: swiftSettings),
        .testTarget(name: "CmuxScreenKitTests", dependencies: ["CmuxScreenKit"], swiftSettings: swiftSettings),
    ]
)
