// swift-tools-version: 6.0

import PackageDescription

// SPM wrapper around the Rust staticlib C FFI over iroh (Native/cmux-iroh),
// built into the gitignored CmuxIrohFFI.xcframework by
// scripts/ensure-cmux-iroh.sh. The xcframework is a pure binary (no Headers);
// the CmuxIrohFFI C target owns the hand-maintained header and gives Swift a
// real module, while CmuxIrohFFIBinary supplies the symbols at link time.
// Both apps link it through this package (the macOS app as a package product,
// the iOS app via CmuxMobileTransport) so every build lane proves the slice
// matrix. No code references it until the iroh transport lands
// (plans/feat-ios-iroh/DESIGN.md PR 3).
let package = Package(
    name: "CmuxIrohFFI",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIrohFFI",
            targets: ["CmuxIrohFFI"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "CmuxIrohFFIBinary",
            path: "../../../CmuxIrohFFI.xcframework"
        ),
        .target(
            name: "CmuxIrohFFI",
            dependencies: ["CmuxIrohFFIBinary"],
            linkerSettings: [
                // iroh's netdev/portmapper layers use these on Apple platforms
                // (found empirically in the spike; see
                // experiments/iroh-swift-ffi-spike/build.sh).
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("Network", .when(platforms: [.iOS])),
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
