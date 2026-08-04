// swift-tools-version: 6.0

import PackageDescription

// `CmuxMobileCrashReporting` is the iOS crash telemetry leaf package. It owns
// the Sentry startup options for mobile, including watchdog termination,
// app-hang, and MetricKit diagnostics, while depending on `CmuxMobileAnalytics`
// only for the shared telemetry consent seam so crash reporting follows the
// same opt-out as analytics.
let package = Package(
    name: "CmuxMobileCrashReporting",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileCrashReporting",
            targets: ["CmuxMobileCrashReporting"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileAnalytics"),
        .package(path: "../../Shared/CmuxSentryTelemetry"),
        .package(
            url: "https://github.com/manaflow-ai/sentry-cocoa.git",
            revision: "c276db5ef78325d350e09176fb9b25c459940a89"
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileCrashReporting",
            dependencies: [
                "CmuxMobileAnalytics",
                .product(name: "CmuxSentryScrubbing", package: "CmuxSentryTelemetry"),
                .product(name: "CmuxSentryReporting", package: "CmuxSentryTelemetry"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileCrashReportingTests",
            dependencies: ["CmuxMobileCrashReporting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
