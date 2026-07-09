public import CmuxMobileAnalytics
import Foundation
public import Sentry

/// Starts Sentry-backed crash reporting for the iOS app.
///
/// ``MobileCrashReporter`` intentionally reuses
/// ``CmuxMobileAnalytics/AnalyticsConsentProviding`` so crash telemetry and
/// analytics obey one opt-out source. No custom iOS breadcrumbs or messages are
/// sent in this first pass: `sendDefaultPii` is disabled, and reports are
/// limited to crash, watchdog, MetricKit, app-hang, stack, and device context
/// until the macOS scrubber can be moved to a shared package.
public struct MobileCrashReporter {
    /// Creates a mobile crash reporter.
    public init() {}

    /// Starts crash reporting with a default ``MobileCrashReporter`` instance.
    ///
    /// - Parameters:
    ///   - consent: The shared analytics/crash telemetry opt-out gate.
    ///   - arguments: Process arguments used to gate the DEBUG-only test crash.
    ///     Defaults to `ProcessInfo.processInfo.arguments`.
    ///   - start: The Sentry start function. Tests inject this closure so they
    ///     can assert the consent gate without starting the real SDK.
    ///   - crash: The DEBUG-only test crash function. Tests inject this closure
    ///     with `--cmux-test-crash` so they can assert trigger gating without
    ///     crashing the test process.
    public static func startIfEnabled(
        consent: any AnalyticsConsentProviding,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        start: (Options) -> Void = { SentrySDK.start(options: $0) },
        crash: () -> Void = { SentrySDK.crash() }
    ) {
        Self().startIfEnabled(
            consent: consent,
            arguments: arguments,
            environment: environment,
            start: start,
            crash: crash
        )
    }

    /// Builds the mobile Sentry options with a default ``MobileCrashReporter`` instance.
    ///
    /// - Returns: A fully configured Sentry ``Options`` value suitable for
    ///   `SentrySDK.start(options:)`.
    public static func makeOptions() -> Options {
        Self().makeOptions()
    }

    /// Starts crash reporting when the shared telemetry consent gate is enabled.
    ///
    /// - Parameters:
    ///   - consent: The shared analytics/crash telemetry opt-out gate.
    ///   - arguments: Process arguments used to gate the DEBUG-only test crash.
    ///     Defaults to `ProcessInfo.processInfo.arguments`.
    ///   - start: The Sentry start function. Tests inject this closure so they
    ///     can assert the consent gate without starting the real SDK.
    ///   - crash: The DEBUG-only test crash function. Tests inject this closure
    ///     with `--cmux-test-crash` so they can assert trigger gating without
    ///     crashing the test process.
    public func startIfEnabled(
        consent: any AnalyticsConsentProviding,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        start: (Options) -> Void = { SentrySDK.start(options: $0) },
        crash: () -> Void = { SentrySDK.crash() }
    ) {
        guard consent.isTelemetryEnabled else { return }
        // Never report from test hosts: XCTest/Swift Testing runs would send
        // CI sessions and deliberate test crashes to the shared Sentry project
        // and add background SDK work to timing-sensitive tests.
        guard environment[Self.xcTestConfigurationKey] == nil else { return }

        start(makeOptions())

        #if DEBUG
        if arguments.contains(Self.debugCrashArgument) {
            crash()
        }
        #endif
    }

    /// Builds the mobile Sentry options without starting the SDK.
    ///
    /// - Returns: A fully configured Sentry ``Options`` value suitable for
    ///   `SentrySDK.start(options:)`.
    public func makeOptions() -> Options {
        let options = Options()
        options.dsn = Self.dsn
        #if DEBUG
        options.environment = "ios-development"
        options.debug = true
        #else
        options.environment = "ios-production"
        options.debug = false
        #endif
        options.tracesSampleRate = 0.0
        options.sendDefaultPii = false
        options.attachStacktrace = true
        options.enableCaptureFailedRequests = false
        options.enableWatchdogTerminationTracking = true
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 8.0
        // Crash/device-context ONLY until the macOS scrubber moves to a shared
        // package: there is no beforeSend scrubber here, so every default that
        // would record or mutate app traffic stays off. Swizzling injects
        // sentry-trace/baggage headers into URLSession requests (which carry
        // auth in this app) and network/auto breadcrumbs record request URLs
        // into crash envelopes; sendDefaultPii does not cover those.
        options.enableSwizzling = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableAutoBreadcrumbTracking = false
        options.tracePropagationTargets = []
        #if canImport(MetricKit) && !os(tvOS) && !os(visionOS)
        // Normalized MetricKit diagnostics only. Raw MXDiagnosticPayload
        // attachments bypass sendDefaultPii and any future event scrubber, so
        // they stay off until a raw-attachment scrub path exists.
        options.enableMetricKit = true
        #endif
        return options
    }

    private static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
    private static let debugCrashArgument = "--cmux-test-crash"
    private static let xcTestConfigurationKey = "XCTestConfigurationFilePath"
}
