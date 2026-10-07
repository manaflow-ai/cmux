// swift-tools-version: 6.0

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
                .product(name: "Sentry", package: "sentry-cocoa"),
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
