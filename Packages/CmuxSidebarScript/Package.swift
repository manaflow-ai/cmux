// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebarScript",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebarScript",
            targets: ["CmuxSidebarScript"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxSidebarScript",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                // The engine runs synchronously on the main thread behind a single
                // entry point; language mode 5 keeps the small interpreter free of
                // Sendable ceremony that buys nothing here.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarScriptTests",
            dependencies: ["CmuxSidebarScript"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
