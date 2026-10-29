// swift-tools-version: 6.2

import PackageDescription

/// The phone's browser tunnel plumbing, independent of what carries the
/// bytes: a SOCKS5 proxy and loopback port forwards on the phone whose
/// connections are opened by a `SocksConnectBackend` (SSH `direct-tcpip`,
/// a paired Mac's irx lanes, or the phone's own network).
let package = Package(
    name: "CmuxMobileTunnel",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileTunnel",
            targets: ["CmuxMobileTunnel"]
        ),
    ],
    dependencies: [
        // OnceContinuation, the continuation that resumes exactly once.
        .package(path: "../../Shared/CmuxSafeConcurrency"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
    ],
    targets: [
        .target(
            name: "CmuxMobileTunnel",
            dependencies: [
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileTunnelTests",
            dependencies: [
                "CmuxMobileTunnel",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "CmuxMobileTunnel",
            "CmuxMobileTunnelTests",
        ],
        settings: [
            .strictMemorySafety(),
        ]
    ),
]
for group in stabilitySettingGroups {
    for target in package.targets where group.targets.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + group.settings
    }
}
// END apply-stability-settings.py
