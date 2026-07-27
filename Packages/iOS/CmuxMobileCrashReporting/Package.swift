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
        .package(
            url: "https://github.com/getsentry/sentry-cocoa.git",
            .upToNextMajor(from: "9.3.0")
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileCrashReporting",
            dependencies: [
                "CmuxMobileAnalytics",
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
