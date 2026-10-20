// swift-tools-version: 6.0

import PackageDescription

// The classic app's local Chief: an in-process conversation owner that keeps
// Home's Chief conversations on disk under one Chief home per build, runs
// each turn through a pluggable `ChiefBrain` (Claude Code, Codex, a fake in
// tests) and serves Home through `ChiefLocalSource`, a `HomeSource`.
let package = Package(
    name: "CmuxChief",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxChief", targets: ["CmuxChief"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxHomeCore"),
        .package(path: "../../Shared/CmuxAgentQuestion"),
    ],
    targets: [
        .target(
            name: "CmuxChief",
            dependencies: [
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxChiefTests",
            dependencies: [
                "CmuxChief",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
