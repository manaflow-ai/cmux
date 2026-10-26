// swift-tools-version: 6.2

import PackageDescription

// A dependency-free RFB (VNC) client engine shared by the cmux-next Mac app
// (the `remote_view` pane's compatibility source, plans/cmux-next/remote-desktop.md
// section 12) and iOS clients. `CmuxVNCDemoServer` is a small loopback RFB
// server that paints a synthetic desktop, for tests and offline demos.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxVNC",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxVNC", targets: ["CmuxVNC"]),
        .library(name: "CmuxVNCDemoServer", targets: ["CmuxVNCDemoServer"]),
    ],
    dependencies: [
        // Test-only: the seeded fuzz suites (p10-stability-023).
        .package(path: "../CmuxFuzzSupport"),
    ],
    targets: [
        .target(name: "CmuxVNC", swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CmuxVNCDemoServer", dependencies: ["CmuxVNC"], swiftSettings: swiftSettings,
                linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "CmuxVNCTests", dependencies: [
            "CmuxVNC", "CmuxVNCDemoServer", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
        ], swiftSettings: swiftSettings),
    ]
)
