// swift-tools-version: 6.2

import PackageDescription

// The threading leaf for code that runs in the macOS app and on iOS (plans/cmux-next/chrome-parity/p02-threads.md,
// task 130): the `blockingCall` seam whose hook the app installs at launch (no-op until then, and on iOS), a `Mutex`
// whose contended waits that hook times, and the `MayBlockRunner` a shared package takes by `init` for its blocking
// work. Foundation-free, so any Shared or iOS package can depend on it, and it builds on Linux for the Linux tier.

/// The p10 compile-time safety settings (scripts/cmux-next/stability-settings.json fills this list).
let stabilitySwiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
]

let packageSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
] + stabilitySwiftSettings

let package = Package(
    name: "CmuxThreading",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxThreading", targets: ["CmuxThreading"]),
    ],
    dependencies: [
        .package(path: "../CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "CmuxThreading",
            dependencies: [
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: packageSwiftSettings
        ),
        .testTarget(
            name: "CmuxThreadingTests",
            dependencies: [
                "CmuxThreading",
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            swiftSettings: packageSwiftSettings
        ),
    ]
)
