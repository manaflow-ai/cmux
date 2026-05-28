// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CMUXMobileCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXMobileCore",
            targets: ["CMUXMobileCore"]
        ),
        .library(
            name: "GhosttyVT",
            targets: ["GhosttyVT"]
        ),
    ],
    targets: [
        // libghostty-vt is the same Zig VT emulator the macOS Ghostty
        // surface runs. Linking the xcframework means iOS feeds bytes
        // into the same parser/grid that the Mac uses, instead of
        // shipping a divergent Swift parser.
        // Note: the binary target's module name must match the
        // modulemap inside the xcframework, which is `GhosttyVt`.
        .binaryTarget(
            name: "GhosttyVt",
            path: "Vendor/ghostty-vt.xcframework"
        ),
        .target(
            name: "GhosttyVT",
            dependencies: ["GhosttyVt"]
        ),
        .target(name: "CMUXMobileCore", dependencies: ["GhosttyVT"]),
        .testTarget(
            name: "CMUXMobileCoreTests",
            dependencies: ["CMUXMobileCore", "GhosttyVT"]
        ),
        .testTarget(
            name: "GhosttyVTTests",
            dependencies: ["GhosttyVT"]
        ),
    ]
)
