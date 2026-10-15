// swift-tools-version: 6.0

import PackageDescription

// The embedded Chromium (CEF) engine for cmux: the Swift side of the CEF shim
// (CEFShim/, built against the pinned artifact by scripts/cef/build-cef-shim.sh
// and loaded with dlopen at run time), the external message pump, the host view
// a page window tracks, and browser handles. Nothing here links CEF: a build
// without the artifact compiles, and the runtime reports the engine as not
// bundled. Ported from cmux Next (Packages/macOS/CmuxNext/CEFShim and
// CmuxNextBrowser/CEF).
let package = Package(
    name: "CmuxCEF",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCEF",
            targets: ["CmuxCEF"]
        ),
        .library(
            name: "CmuxCEFBrowser",
            targets: ["CmuxCEFBrowser"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxBrowser"),
    ],
    targets: [
        .target(
            name: "CmuxCEF",
            // The shim's C header: its SHA-256 is the shim ABI identity
            // (CEFShimABI, scripts/cef/build-cef-shim.sh).
            resources: [
                .copy("Shim/cmux_cef_shim.h"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        // The Chromium engine behind CmuxBrowser's engine-neutral page protocols. CmuxCEF itself
        // has no CmuxBrowser dependency.
        .target(
            name: "CmuxCEFBrowser",
            dependencies: [
                "CmuxCEF",
                .product(name: "CmuxBrowser", package: "CmuxBrowser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCEFBrowserTests",
            dependencies: [
                "CmuxCEF",
                "CmuxCEFBrowser",
                .product(name: "CmuxBrowser", package: "CmuxBrowser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCEFTests",
            dependencies: ["CmuxCEF"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
