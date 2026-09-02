public import CMUXMobileCore
import CmuxSentryReporting
import Foundation
public import Sentry

/// Starts Sentry-backed crash reporting for the iOS app.
///
/// ``MobileCrashReporter`` intentionally reuses
/// ``CMUXMobileCore/AnalyticsConsentProviding`` so crash telemetry and
/// analytics obey one opt-out source. `sendDefaultPii` is disabled and every
/// outgoing event, breadcrumb, and structured log is redacted by the shared
/// `SentryEventScrubber` (CmuxSentryReporting) before it leaves the device.
/// Structured logs are enabled so the transport diagnostics bridge can emit
/// searchable connection telemetry; swizzling and automatic network capture
/// stay off because URLSession traffic in this app carries auth.
public struct MobileCrashReporter {
    private let transportSessionController: any MobileCrashTransportSessionControlling
    private let cachePurger: SentryCachePurger
    private let scrubber = SentryEventScrubber()

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
    ///   - prepareLocale: Process-locale initialization performed before Sentry
    ///     starts any background work.
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
        replayMaskedViewClasses: [AnyClass] = [],
        prepareLocale: () -> Void = {
            _ = Locale.current
            _ = NSLocale.preferredLanguages
        },
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
        // Foundation lazily initializes process locale through setlocale().
        // Sentry also starts a background `sentry-init` thread that reads
        // locale environment state. Completing Foundation's initialization on
        // the composition-root actor first prevents that thread from racing
        // libghostty's own locale initialization when its first surface mounts.
        prepareLocale()
        let cachePurger = self.cachePurger
        let purgeCache = purgeCache ?? { cachePurger.purge() }

        let startReporting = {
            let options = makeOptions(
                environment: environment,
                replayMaskedViewClasses: replayMaskedViewClasses
            )
            // Sentry's close() always flushes. A dedicated transport session
            // lets revocation cancel queued and in-flight requests before close
            // attempts that flush; a zero timeout prevents shutdown waiting.
            options.urlSession = transportSessionController.makeSession()
            options.shutdownTimeInterval = 0
            // Consent is re-read per envelope, mirroring the analytics
            // emitter's per-capture gate: flipping sendAnonymousTelemetry off
            // mid-session drops every subsequent envelope (crash, hang,
            // MetricKit, structured log) without requiring a relaunch. Events
            // and logs that do ship are scrubbed last-mile.
            let scrubber = self.scrubber
            options.beforeSend = { event in
                consent.isTelemetryEnabled ? scrubber.scrub(event) : nil
            }
            options.beforeSendLog = { log in
                consent.isTelemetryEnabled ? scrubber.scrub(log) : nil
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
    /// - Parameters:
    ///   - environment: Process environment, read for the DEBUG-only
    ///     `CMUX_REPLAY_FORCE_SESSION` mask-audit override.
    ///   - replayMaskedViewClasses: View classes replay must always mask, on
    ///     top of the text/image/webview defaults. The composition root passes
    ///     every content surface here (terminal, browser stream, sim stream,
    ///     camera) because Metal- and video-backed views are not covered by
    ///     the class-based defaults.
    /// - Returns: A fully configured Sentry ``Options`` value suitable for
    ///   `SentrySDK.start(options:)`.
    public func makeOptions(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        replayMaskedViewClasses: [AnyClass] = []
    ) -> Options {
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
        // Structured logs power the transport diagnostics bridge
        // (TransportSentryReporter); each log line passes the consent gate and
        // scrubber installed in `beforeSendLog`.
        options.enableLogs = true
        // Manual breadcrumbs (the transport bridge's) are scrubbed last-mile.
        // Swizzling and automatic network capture stay OFF even with the
        // scrubber in place: swizzling injects sentry-trace/baggage headers
        // into URLSession requests, which carry auth in this app, and that
        // egress is not something a beforeSend hook can redact.
        let scrubber = self.scrubber
        options.beforeBreadcrumb = { breadcrumb in
            scrubber.scrub(breadcrumb)
        }
        options.enableSwizzling = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableAutoBreadcrumbTracking = false
        options.tracePropagationTargets = []
        // Sessions are release-health telemetry, outside the crash-only scope,
        // and the one envelope type the consent beforeSend gate cannot drop.
        options.enableAutoSessionTracking = false
        #if os(iOS)
        // Session replay: masked recordings of the app's own screens for crash
        // and UX context. Masking runs on-device during capture, so masked
        // pixels are never encoded or uploaded. Text/image/webview defaults
        // stay on, and the injected class list unconditionally masks content
        // surfaces the defaults cannot classify (Metal terminal, streamed
        // browser/sim video, camera preview). Replay consent is enforced on
        // three layers: the revocation watcher only starts the SDK with
        // consent on; replay events route through the `beforeSend` consent
        // gate like any other event (the scrubber returns the same instance,
        // which SentryClient requires for replays); and revocation cancels
        // transport and purges `Caches/io.sentry`, which holds buffered
        // replay segments. Touch capture stays off because it requires
        // `enableSwizzling`.
        options.sessionReplay.onErrorSampleRate = 1.0
        options.sessionReplay.sessionSampleRate = 0.1
        options.sessionReplay.quality = .low
        options.sessionReplay.maskAllText = true
        options.sessionReplay.maskAllImages = true
        options.sessionReplay.maskedViewClasses = replayMaskedViewClasses
        // CALayer-only rendering can omit views entirely; keep the complete
        // renderer so masked regions are drawn as blocks, not skipped.
        options.sessionReplay.enableFastViewRendering = false
        #if DEBUG
        // Mask-audit override: force a full-session replay so every screen
        // can be walked once and inspected in Sentry for mask leaks.
        if environment["CMUX_REPLAY_FORCE_SESSION"] == "1" {
            options.sessionReplay.sessionSampleRate = 1.0
        }
        #endif
        #endif
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

    // The dedicated cmux-ios Sentry project. The macOS app reports to
    // cmuxterm-macos; keeping the platforms in separate projects gives iOS its
    // own rate limits, alerts, and dSYM store instead of sharing the macOS
    // project's.
    private static let dsn = "https://834d19a3077c4adbff534dca1e93de4f@o4507547940749312.ingest.us.sentry.io/4510604800491520"
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
