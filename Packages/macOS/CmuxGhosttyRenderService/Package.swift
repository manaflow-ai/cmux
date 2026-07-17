// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let ghosttyArchivePath = packageDirectory
    .appendingPathComponent(
        "../../../GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"
    )
    .standardizedFileURL
    .path

let package = Package(
    name: "CmuxGhosttyRenderService",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxGhosttyRenderClient",
            targets: ["CmuxGhosttyRenderClient"]
        ),
        .library(
            name: "CmuxGhosttyRenderWorker",
            targets: ["CmuxGhosttyRenderWorker"]
        ),
        .executable(
            name: "cmux-ghostty-render-fixture",
            targets: ["cmux-ghostty-render-fixture"]
        ),
        .executable(
            name: "cmux-ghostty-render-worker-test-host",
            targets: ["cmux-ghostty-render-worker-test-host"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalRenderTransport"),
    ],
    targets: [
        .target(
            name: "CmuxGhosttyRenderClient",
            dependencies: [
                .product(
                    name: "CmuxTerminalRenderTransport",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .systemLibrary(
            name: "CmuxGhosttyRenderWorkerGhosttyKit",
            path: "Sources/GhosttyKit"
        ),
        .target(
            name: "CmuxGhosttyRenderWorker",
            dependencies: [
                .product(
                    name: "CmuxTerminalRenderTransport",
                    package: "CmuxTerminalRenderTransport"
                ),
                "CmuxGhosttyRenderWorkerGhosttyKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                // The Ghostty XCFramework's macOS archive lacks SwiftPM's
                // required `lib` prefix. Import its headers through the local
                // shim target and link the same archive explicitly.
                .unsafeFlags([ghosttyArchivePath]),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "cmux-ghostty-render-fixture",
            dependencies: [
                .product(
                    name: "CmuxTerminalRenderTransport",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "cmux-ghostty-render-worker-test-host",
            dependencies: ["CmuxGhosttyRenderWorker"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CmuxGhosttyRenderClientTests",
            dependencies: [
                "CmuxGhosttyRenderClient",
                "cmux-ghostty-render-fixture",
                "cmux-ghostty-render-worker-test-host",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
