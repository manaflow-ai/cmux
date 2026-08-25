// swift-tools-version: 6.0

import PackageDescription

// `CmuxMobileCrashReporting` is the iOS crash telemetry leaf package. It owns
// the Sentry startup options for mobile, including watchdog termination,
// app-hang, and MetricKit diagnostics. It depends on the telemetry consent seam
// in `CMUXMobileCore`, making crash reporting and analytics sibling consumers
// of the same opt-out contract.
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
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxSentryTelemetry"),
        .package(
            url: "https://github.com/getsentry/sentry-cocoa.git",
            .upToNextMajor(from: "9.3.0")
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileCrashReporting",
            dependencies: [
                "CMUXMobileCore",
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
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobileCrashReporting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
