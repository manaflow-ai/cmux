// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryDirectory = packageDirectory.appendingPathComponent("../../..").standardizedFileURL
// Keep the stable repository symlink in the linker invocation. Resolving it in
// the manifest lets SwiftPM cache a prior GhosttyKit pin across symlink updates.
let ghosttyArchive = repositoryDirectory.path
    + "/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"
let ghosttyIncludeDirectory = repositoryDirectory.appendingPathComponent("ghostty/include").path
let ghosttyModuleMap = repositoryDirectory.appendingPathComponent("ghostty/include/module.modulemap").path

let package = Package(
    name: "CmuxTerminalRenderer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalRenderer",
            targets: ["CmuxTerminalRenderer"]
        ),
        .executable(
            name: "CmuxTerminalRendererWorker",
            targets: ["CmuxTerminalRendererWorker"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTerminalRenderer",
            dependencies: ["RendererMachBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "RendererMachBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CmuxTerminalRendererWorker",
            dependencies: ["CmuxTerminalRenderer"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .unsafeFlags([
                    "-Xcc", "-fmodule-map-file=\(ghosttyModuleMap)",
                    "-Xcc", "-I\(ghosttyIncludeDirectory)",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([ghosttyArchive]),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalRendererTests",
            dependencies: ["CmuxTerminalRenderer"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
