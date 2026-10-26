// swift-tools-version: 6.0

import PackageDescription

// Seeded property tests for decoders and state machines (p10-stability-016): one
// xorshift RNG, byte and token mutators, a corpus loader, long mode
// (CMUX_FUZZ_SECONDS, CMUX_FUZZ_SEED) and failing inputs written to
// CMUX_FUZZ_ARTIFACTS. Test-only: only test targets depend on it. It imports
// Foundation alone, so the Linux libFuzzer wrappers (p10-stability-182) can reuse
// each suite's `oneInput(_:)` body. These are seeded property tests, not
// coverage-guided FuzzTest.
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
            ]
        ),
        .testTarget(
            name: "CmuxFuzzSupportTests",
            dependencies: ["CmuxFuzzSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
