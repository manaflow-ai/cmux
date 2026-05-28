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
        // Keep the GhosttyVT binary target out of CMUXMobileCore's default
        // graph. The macOS app links GhosttyKit already, and Xcode copies
        // both xcframework module maps to the same product include path if
        // CMUXMobileCore pulls this binary in transitively.
        .target(name: "CMUXMobileCore"),
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
