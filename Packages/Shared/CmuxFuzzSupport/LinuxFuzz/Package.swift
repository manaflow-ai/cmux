// swift-tools-version: 6.2

import PackageDescription

// Coverage-guided Swift fuzz targets (p10-stability-182): one executable product per decoder,
// built with -sanitize=fuzzer,address by scripts/cmux-next/swift-libfuzzer.sh on Linux, or on a
// fleet Mac whose toolchain ships the libFuzzer runtime. Nothing ships from here and no other
// package depends on it.
//
// A target that wraps a property suite links the suite's own file (a symlink into its Tests
// folder), so the fuzzer runs the same `oneInput(_:)` the test runs; the script builds with
// -enable-testing for the suite's `@testable import`. A decoder whose package needs Darwin-only
// frameworks (CryptoKit, Network, IrohLib, AVFoundation) is built from its Foundation-only files
// under the package's module name: the `CmuxIrxTransport`, `CmuxIrohTransport` and `CmuxHomeCore`
// targets below are symlinks to those files.
//
// Not fuzzed here, with the reason: CmuxVNC (its RFB decoders read through an async transport and
// import CoreGraphics and the Darwin zlib module), CmuxScreenKit and CmuxHomeRender (UIKit, Core
// Graphics, QuartzCore; async or main-actor bodies), MessagesLab's HomeMarkdown (UIKit).

// The p10 compile-time safety settings the linked sources' own packages build with.
let stabilitySwiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
]
let fuzzSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)] + stabilitySwiftSettings

let fuzzSupport: Target.Dependency = .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")
let mobileCore: Target.Dependency = .product(name: "CMUXMobileCore", package: "CMUXMobileCore")

/// The fuzz targets: `Sources/<name>/main.swift`, plus the suite file a wrapper links.
let fuzzers: [(name: String, dependencies: [Target.Dependency])] = [
    ("MobileProtocolFuzzer", [fuzzSupport, mobileCore]),
    ("MobileRenderGridFuzzer", [fuzzSupport, mobileCore]),
    ("MobileSyncFrameFuzzer", [fuzzSupport, mobileCore]),
    ("TerminalSizingFuzzer", [fuzzSupport, .product(name: "CmuxTerminalSizing", package: "CmuxTerminalSizing")]),
    ("TerminalStreamFuzzer", [fuzzSupport, .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream")]),
    ("IrxFrameFuzzer", [fuzzSupport, mobileCore, "CmuxIrxTransport"]),
    ("CmxIrohDecoderFuzzer", [fuzzSupport, mobileCore, "CmuxIrohTransport"]),
    ("HomeWireJSONFuzzer", [fuzzSupport, "CmuxHomeCore"]),
    // swift-libfuzzer.sh --self-test only: one input per finding the script classifies.
    ("SelfTestFuzzer", [fuzzSupport]),
]

let package = Package(
    name: "CmuxLinuxFuzz",
    platforms: [.macOS(.v14)],
    products: fuzzers.map { .executable(name: $0.name, targets: [$0.name]) },
    dependencies: [
        .package(path: ".."),
        .package(path: "../../CMUXMobileCore"),
        .package(path: "../../CmuxTerminalSizing"),
        .package(path: "../../CmuxTerminalStream"),
    ],
    targets: [
        .systemLibrary(name: "CLibFuzzer"),
        .target(name: "LibFuzzerDriver", dependencies: ["CLibFuzzer"], swiftSettings: fuzzSettings),
        .target(name: "CmuxIrxTransport", swiftSettings: fuzzSettings),
        .target(name: "CmuxIrohTransport", dependencies: [mobileCore], swiftSettings: fuzzSettings),
        .target(name: "CmuxHomeCore", swiftSettings: fuzzSettings),
    ] + fuzzers.map {
        .executableTarget(name: $0.name, dependencies: ["LibFuzzerDriver"] + $0.dependencies, swiftSettings: fuzzSettings)
    }
)
