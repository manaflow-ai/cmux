// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The Rust client (cmux-tui/crates/cmux-terminal-client) arrives as a prebuilt
// xcframework. Two sources, chosen when this manifest is evaluated:
//
//   * CmuxTerminalClient.xcframework next to this file, when a developer has
//     downloaded one from a workflow run (the directory is gitignored);
//   * otherwise the release zip pinned below, produced by
//     .github/workflows/cmux-terminal-client-xcframework.yml.
//
// Set CMUX_TERMINAL_CLIENT_FORCE_REMOTE_XCFRAMEWORK to ignore a local copy.
// Set CMUX_TERMINAL_CLIENT_MODEL_ONLY to build and test only the pure Swift
// model target, for a checkout with no binary available at all.
let releaseRepository = "manaflow-ai/cmux"
let releaseTag = "cmux-terminal-client-v0.1.0+PENDING"
let releaseChecksum = "PENDING"

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localXcframework = packageDir.appendingPathComponent("CmuxTerminalClient.xcframework")
let forceRemote =
    ProcessInfo.processInfo.environment["CMUX_TERMINAL_CLIENT_FORCE_REMOTE_XCFRAMEWORK"] != nil
let useLocal =
    !forceRemote
    && FileManager.default.fileExists(atPath: localXcframework.appendingPathComponent("Info.plist").path)

let ffiBinary: Target =
    useLocal
    ? .binaryTarget(name: "CmuxTerminalClientFFI", path: "CmuxTerminalClient.xcframework")
    : .binaryTarget(
        name: "CmuxTerminalClientFFI",
        url:
            "https://github.com/\(releaseRepository)/releases/download/\(releaseTag)/CmuxTerminalClient.xcframework.zip",
        checksum: releaseChecksum)

let modelOnly = ProcessInfo.processInfo.environment["CMUX_TERMINAL_CLIENT_MODEL_ONLY"] != nil

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxTerminalClient",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: modelOnly
        ? [.library(name: "CmuxTerminalClientModel", targets: ["CmuxTerminalClientModel"])]
        : [
            .library(name: "CmuxTerminalClientKit", targets: ["CmuxTerminalClientKit"]),
            .library(name: "CmuxTerminalClientModel", targets: ["CmuxTerminalClientModel"]),
        ],
    targets: [
        // Pure Swift: result decoding and request shaping, testable without
        // the binary.
        .target(
            name: "CmuxTerminalClientModel",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxTerminalClientModelTests",
            dependencies: ["CmuxTerminalClientModel"],
            swiftSettings: swiftSettings
        ),
    ] + (modelOnly
        ? []
        : [
            // The Swift face of the C ABI.
            .target(
                name: "CmuxTerminalClientKit",
                dependencies: ["CmuxTerminalClientModel", "CmuxTerminalClientFFI"],
                swiftSettings: swiftSettings,
                linkerSettings: [
                    .linkedFramework("Security"),
                    .linkedFramework("SystemConfiguration"),
                    .linkedLibrary("resolv"),
                ]
            ),
            ffiBinary,
        ])
)
