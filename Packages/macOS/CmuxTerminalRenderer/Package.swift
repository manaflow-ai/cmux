// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalRenderer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalRendererRuntime",
            targets: ["CmuxTerminalRendererRuntime"]
        ),
        .executable(
            name: "cmux-terminal-renderer",
            targets: ["CmuxTerminalRendererWorker"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxTerminalRenderTransport"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttySceneRendererKit",
            path: "../../../GhosttySceneRendererKit.xcframework"
        ),
        .target(
            name: "CmuxTerminalRendererRuntime",
            dependencies: [
                .product(
                    name: "CmuxTerminalRenderProtocol",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRendererControl",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .executableTarget(
            name: "CmuxTerminalRendererWorker",
            dependencies: [
                "CmuxTerminalRendererRuntime",
                "GhosttySceneRendererKit",
                .product(
                    name: "CmuxTerminalRenderProtocol",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRendererControl",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRenderTransport",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalRendererRuntimeTests",
            dependencies: [
                "CmuxTerminalRendererRuntime",
                .product(
                    name: "CmuxTerminalRenderProtocol",
                    package: "CmuxTerminalRenderTransport"
                ),
                .product(
                    name: "CmuxTerminalRendererControl",
                    package: "CmuxTerminalRenderTransport"
                ),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalRendererGhosttyTests",
            dependencies: ["GhosttySceneRendererKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
