// swift-tools-version: 6.0

import Foundation
import PackageDescription

// `CmuxSentryTelemetry` is the shared (macOS + iOS) Sentry privacy and
// transport-telemetry layer. `CmuxSentryScrubbing` is the pure-Foundation
// value scrubber (no Sentry dependency) so it stays testable without linking
// the SDK; `CmuxSentryReporting` is the glue that routes Sentry `Event` /
// `Breadcrumb` / `Span` / `SentryLog` fields through that scrubber and bridges
// the CMUXMobileCore transport diagnostic stream into Sentry, so it links the
// Sentry SDK.
let package = Package(
    name: "CmuxSentryTelemetry",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSentryScrubbing",
            targets: ["CmuxSentryScrubbing"]
        ),
        .library(
            name: "CmuxSentryReporting",
            targets: ["CmuxSentryReporting"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(
            // sentry-cocoa 9.29.0 removed PrivateSentrySDKOnly, which the cmux
            // CLI uses to store envelopes (CLI/CLISocketSentryTelemetry.swift).
            // Keep the cap until that call moves to a public API.
            url: "https://github.com/getsentry/sentry-cocoa.git",
            "9.3.0"..<"9.29.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxSentryScrubbing",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxSentryReporting",
            dependencies: [
                "CmuxSentryScrubbing",
                "CMUXMobileCore",
                // macOS links the dynamic SDK: a static Sentry adds the
                // Objective-C personality routine to the cmux-next app image,
                // one more than compact unwind encodes (C++, iroh-ffi and
                // CCmuxAppFFI already use the three; check-app-personalities.sh).
                .product(name: "Sentry", package: "sentry-cocoa", condition: .when(platforms: [.iOS])),
                .product(name: "Sentry-Dynamic", package: "sentry-cocoa", condition: .when(platforms: [.macOS])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSentryScrubbingTests",
            dependencies: ["CmuxSentryScrubbing"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSentryReportingTests",
            dependencies: ["CmuxSentryReporting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

#if os(Linux)
// sentry-cocoa is Apple-only: a build for Linux builds the scrubber and its tests alone. Only the Linux
// package jobs (swift-packages-linux.yml) set CMUX_SWIFTPM_TARGET_LINUX: the fleet's app compile also
// reads this manifest on a Linux host, but builds for macOS and needs CmuxSentryReporting.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.products.removeAll { $0.name == "CmuxSentryReporting" }
    package.targets.removeAll { $0.name == "CmuxSentryReporting" || $0.name == "CmuxSentryReportingTests" }
    package.dependencies.removeAll()
}
#endif
