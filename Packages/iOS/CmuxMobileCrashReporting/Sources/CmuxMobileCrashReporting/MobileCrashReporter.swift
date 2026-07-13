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
    private let transportSessionController: any MobileCrashTransportSessionControlling
    private let cachePurger: SentryCachePurger

    /// Creates a mobile crash reporter.
    public init() {
        self.init(
            transportSessionController: MobileCrashTransportSessionController(),
            cachePurger: SentryCachePurger()
        )
    }

    init(
        transportSessionController: any MobileCrashTransportSessionControlling,
        cachePurger: SentryCachePurger = SentryCachePurger()
    ) {
        self.transportSessionController = transportSessionController
        self.cachePurger = cachePurger
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
        notificationCenter: NotificationCenter = .default,
        revocationWatcher: RevocationWatcher,
        start: @escaping (Options) -> Void = { SentrySDK.start(options: $0) },
        close: @escaping @Sendable () -> Void = { SentrySDK.close() },
        purgeCache: (@Sendable () -> Void)? = nil,
        crash: @escaping () -> Void = { SentrySDK.crash() }
    ) {
        // Never report from test runs: unit-test hosts, XCUITest
        // app-under-test launches (which do NOT get XCTestConfigurationFilePath;
        // they carry other XCTest markers or this repo's CMUX_UITEST_ keys),
        // and CI sessions would all send deliberate crashes and hangs to the
        // shared Sentry project.
        guard !isTestRun(environment: environment) else { return }
        let cachePurger = self.cachePurger
        let purgeCache = purgeCache ?? { cachePurger.purge() }

        let startReporting = {
            let options = makeOptions()
            // Sentry's close() always flushes. A dedicated transport session
            // lets revocation cancel queued and in-flight requests before close
            // attempts that flush; a zero timeout prevents shutdown waiting.
            options.urlSession = transportSessionController.makeSession()
            options.shutdownTimeInterval = 0
            // Consent is re-read per event, mirroring the analytics emitter's
            // per-capture gate: flipping sendAnonymousTelemetry off mid-session
            // drops every subsequent envelope (crash, hang, MetricKit) without
            // requiring a relaunch.
            options.beforeSend = { event in
                consent.isTelemetryEnabled ? event : nil
            }
            start(options)

            #if DEBUG
            if arguments.contains(Self.debugCrashArgument) {
                crash()
            }
            #endif
        }
        let stopReporting = {
            // Cancel transport first. Sentry's close() always asks its transport
            // to flush, even with a zero timeout, so invalidating the dedicated
            // session is what prevents queued or in-flight envelopes from
            // crossing the consent boundary.
            transportSessionController.invalidateAndCancel()
            purgeCache()
            close()
            purgeCache()
        }

        // Keep monitoring both consent directions for the process lifetime.
        // This starts Sentry immediately after a mid-session opt-in and closes
        // it after opt-out, while transition tracking prevents defaults churn
        // from initializing or closing the SDK more than once.
        revocationWatcher.arm(
            consent: consent,
            notificationCenter: notificationCenter,
            onEnable: startReporting,
            onRevoke: stopReporting,
            onInitiallyDisabled: purgeCache
        )
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
        // Sessions are release-health telemetry, outside the crash-only scope,
        // and the one envelope type the consent beforeSend gate cannot drop.
        options.enableAutoSessionTracking = false
        #if canImport(MetricKit) && !os(tvOS) && !os(visionOS)
        // Normalized MetricKit diagnostics only. Raw MXDiagnosticPayload
        // attachments bypass sendDefaultPii and any future event scrubber, so
        // they stay off until a raw-attachment scrub path exists.
        options.enableMetricKit = true
        #endif
        return options
    }

    /// Process-lifetime telemetry-consent watcher used by the app composition root.
    public typealias RevocationWatcher = MobileCrashRevocationWatcher

    private func isTestRun(environment: [String: String]) -> Bool {
        for key in Self.testEnvironmentKeys where environment[key] != nil {
            return true
        }
        return environment.keys.contains { key in
            Self.testEnvironmentKeyPrefixes.contains { key.hasPrefix($0) }
        }
    }

    private static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
    private static let debugCrashArgument = "--cmux-test-crash"
    private static let testEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
    ]
    private static let testEnvironmentKeyPrefixes = [
        "XCInjectBundle",
        "CMUX_UITEST_",
    ]
}
