// swift-tools-version: 6.2

import PackageDescription

// Seeded property tests for decoders and state machines: one
// xorshift RNG, byte and token mutators, a corpus loader, long mode
// (CMUX_FUZZ_SECONDS, CMUX_FUZZ_DEADLINE), replay (CMUX_FUZZ_SEED,
// CMUX_FUZZ_ITERATIONS) and failing inputs written to
// CMUX_FUZZ_ARTIFACTS. Test-only: only test targets depend on it. It imports
// Foundation alone, so the Linux libFuzzer wrappers can reuse
// each suite's `oneInput(_:)` body. These are seeded property tests, not
// coverage-guided FuzzTest.

// The p10 compile-time safety settings (scripts/cmux-next/stability-settings.json); the
// lander (scripts/cmux-next/apply-stability-settings.py) owns this literal.
let stabilitySwiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
]

let package = Package(
    name: "CmuxFuzzSupport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxFuzzSupport", targets: ["CmuxFuzzSupport"]),
    ],
    targets: [
        .target(
            name: "CmuxFuzzSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ] + stabilitySwiftSettings
        ),
        .testTarget(
            name: "CmuxFuzzSupportTests",
            dependencies: ["CmuxFuzzSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)] + stabilitySwiftSettings
        ),
    ]
)
