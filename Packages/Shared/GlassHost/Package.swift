// swift-tools-version: 6.0

import PackageDescription

// GlassHost: native glass under a see-through web view, positioned by the page. AppKit only, no
// dependencies (README.md). The web half is webviews/src/glass-host.
let package = Package(
    name: "GlassHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "GlassHost", targets: ["GlassHost"]),
    ],
    targets: [
        .target(name: "GlassHost", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "GlassHostTests", dependencies: ["GlassHost"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
