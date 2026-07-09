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
        notificationCenter: NotificationCenter = .default,
        revocationWatcher: RevocationWatcher = .shared,
        start: (Options) -> Void = { SentrySDK.start(options: $0) },
        close: @escaping @Sendable () -> Void = { SentrySDK.close() },
        purgeCache: @escaping @Sendable () -> Void = { Self.purgeSentryCache() },
        crash: () -> Void = { SentrySDK.crash() }
    ) {
        Self().startIfEnabled(
            consent: consent,
            arguments: arguments,
            environment: environment,
            notificationCenter: notificationCenter,
            revocationWatcher: revocationWatcher,
            start: start,
            close: close,
            purgeCache: purgeCache,
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
        notificationCenter: NotificationCenter = .default,
        revocationWatcher: RevocationWatcher = .shared,
        start: (Options) -> Void = { SentrySDK.start(options: $0) },
        close: @escaping @Sendable () -> Void = { SentrySDK.close() },
        purgeCache: @escaping @Sendable () -> Void = { Self.purgeSentryCache() },
        crash: () -> Void = { SentrySDK.crash() }
    ) {
        guard consent.isTelemetryEnabled else {
            // A crash captured during an earlier opted-out window must never
            // upload after a later re-opt-in: with consent off, any envelopes
            // Sentry persisted before the opt-out landed are deleted.
            purgeCache()
            return
        }
        // Never report from test runs: unit-test hosts, XCUITest
        // app-under-test launches (which do NOT get XCTestConfigurationFilePath;
        // they carry other XCTest markers or this repo's CMUX_UITEST_ keys),
        // and CI sessions would all send deliberate crashes and hangs to the
        // shared Sentry project.
        guard !Self.isTestRun(environment: environment) else { return }

        let options = makeOptions()
        // Consent is re-read per event, mirroring the analytics emitter's
        // per-capture gate: flipping sendAnonymousTelemetry off mid-session
        // drops every subsequent envelope (crash, hang, MetricKit) without
        // requiring a relaunch.
        options.beforeSend = { event in
            consent.isTelemetryEnabled ? event : nil
        }
        start(options)
        // Mid-session revocation fails closed at the SDK level too: the crash
        // handlers stop persisting reports and cached envelopes are deleted, so
        // nothing captured after (or pending from before) the opt-out can ever
        // leave the device. Re-enabling takes effect on the next launch.
        revocationWatcher.arm(
            consent: consent,
            notificationCenter: notificationCenter,
            onRevoke: {
                // Purge BEFORE close: close() flushes pending envelopes to the
                // network, so persisted opted-out data must be gone first. The
                // second purge removes anything close() persisted while
                // draining its in-memory queue.
                purgeCache()
                close()
                purgeCache()
            }
        )

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

    /// Watches for the shared telemetry opt-out flipping off after Sentry has
    /// started and closes the SDK + purges its cache exactly once. UserDefaults
    /// changes are observed via `UserDefaults.didChangeNotification`, the same
    /// backing store the consent provider reads.
    public final class RevocationWatcher: @unchecked Sendable {
        // lint:allow singleton — process-lifetime default for the production
        // observer registration; tests inject fresh instances.
        public static let shared = RevocationWatcher()

        /// Tests inject fresh instances so parallel suites cannot stomp each
        /// other's registration on the shared watcher.
        public init() {}

        // lint:allow lock — sanctioned carve-out: guards a token swap across
        // the notification-delivery thread and arm callers; an actor would
        // force async hops into the synchronous notification callback.
        private let lock = NSLock()
        private var token: (any NSObjectProtocol)?
        private var center: NotificationCenter?

        func arm(
            consent: any AnalyticsConsentProviding,
            notificationCenter: NotificationCenter,
            onRevoke: @escaping @Sendable () -> Void
        ) {
            lock.lock()
            defer { lock.unlock() }
            if let token, let center { center.removeObserver(token) }
            center = notificationCenter
            token = notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                // Strong self on purpose: the observation (and this watcher)
                // must stay alive until revocation fires or a re-arm replaces
                // it; disarm breaks the center->closure->self cycle.
                guard !consent.isTelemetryEnabled else { return }
                self.disarm()
                onRevoke()
            }
        }

        private func disarm() {
            lock.lock()
            defer { lock.unlock() }
            if let token, let center { center.removeObserver(token) }
            token = nil
            center = nil
        }
    }

    /// Deletes Sentry's on-disk stores: the envelope cache (`Caches/io.sentry`)
    /// AND SentryCrash's raw report store (`Caches/SentryCrash/<bundle>`), which
    /// holds crash reports before they are converted into envelopes.
    public static func purgeSentryCache() {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("io.sentry"))
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("SentryCrash"))
    }

    static func isTestRun(environment: [String: String]) -> Bool {
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
