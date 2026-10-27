// swift-tools-version: 6.2

import PackageDescription

// The concurrency primitives every package of the app's closure may use on the macOS 14 / iOS 17 floor
// (plans/cmux-next/chrome-parity/p10-stability.md, tasks 172, 083 and 081): `Mutex` with the API of
// `Synchronization.Mutex` (macOS 15 / iOS 18), the raw `PlatformLock` under it, `OnceContinuation`, the
// continuation that resumes exactly once (`withOnceContinuation`), and the lock-free `CallbackRegistry`
// that C callbacks take tokens from. Foundation-free, so any package can depend on it, and it builds on
// Linux (pthread mutex) for the Linux tier. It is the only place in Packages/ that calls os_unfair_lock_lock.

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
    name: "CmuxSafeConcurrency",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxSafeConcurrency", targets: ["CmuxSafeConcurrency"]),
    ],
    targets: [
        // The atomic instructions on the macOS 14 / iOS 17 floor, where Synchronization.Atomic is not
        // available: static inline C over the compiler's atomic builtins (no package dependency to resolve).
        // settings-allow: C target, no Swift sources (CmuxSafeConcurrencyAtomics.c and its header)
        .target(name: "CmuxSafeConcurrencyAtomics"),
        .target(
            name: "CmuxSafeConcurrency",
            dependencies: ["CmuxSafeConcurrencyAtomics"],
            swiftSettings: packageSwiftSettings
        ),
        .testTarget(
            name: "CmuxSafeConcurrencyTests",
            dependencies: ["CmuxSafeConcurrency"],
            swiftSettings: packageSwiftSettings
        ),
    ]
)
