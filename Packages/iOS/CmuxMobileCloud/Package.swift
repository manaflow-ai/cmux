// swift-tools-version: 6.0

import PackageDescription

// Domain package for cmux Cloud on the phone: the `/api/vm` client, the
// device's WireGuard identity, the wg-quick config the in-process tunnel
// consumes, and the session controller that owns tunnel and link lifecycle.
//
// It deliberately does NOT depend on `CmuxTerminalClient`: the Rust client
// arrives as a prebuilt binary, and this package must build and test without
// it. The transport is a protocol seam (`CloudTerminalTransport.swift`) that
// the composition root satisfies with the Kit.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxMobileCloud",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileCloud", targets: ["CmuxMobileCloud"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobileCloud",
            dependencies: ["CMUXMobileCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxMobileCloudTests",
            dependencies: ["CmuxMobileCloud"],
            swiftSettings: swiftSettings
        ),
    ]
)
