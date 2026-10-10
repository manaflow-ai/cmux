public import CmuxSentryReporting
public import Darwin
public import Foundation
public import Sentry
import CmuxNextCompat

/// Sends cmux-next crashes (signals, Mach exceptions, uncaught Objective-C
/// exceptions, app hangs) to Sentry, under ``CrashReportingPolicy``.
///
/// Same options as the main app (`AppDelegate`): no default PII, no
/// performance tracing (its root transaction cannot be scrubbed), 8 s app
/// hangs, every event, breadcrumb and span through `SentryEventScrubber`.
/// No structured logs: cmux-next has no log bridge, so it sends nothing the
/// main app does not.
///
/// Signal order. Start after the run marker installs its handlers
/// (`AppRunMarker`): Sentry saves them as the previous handlers and calls
/// them after its report. Chromium resets every signal action at its start;
/// call ``reassertSignalHandlers()`` after the run marker installs its
/// handlers again.
public final class CrashReporter: Sendable {
    /// The DSN of the macOS app's Sentry project (`manaflow/cmuxterm-macos`),
    /// as in the main app; cmux-next events are told apart by
    /// ``CrashEventLabels``.
    public static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
    /// Signals Sentry handles as crashes.
    public static let fatalSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP]
    /// Signals the app owns and Sentry's start must not take: SIGPIPE is a
    /// no-op handler (`ChildSignalDefaults`), SIGTERM a requested quit.
    public static let appOwnedSignals: [Int32] = [SIGPIPE, SIGTERM]

    public let policy: CrashReportingPolicy
    private let sentryHandlers = Mutex<SignalActions?>(nil)

    public init(policy: CrashReportingPolicy) {
        self.policy = policy
    }

    /// Whether Sentry runs in this process.
    public var isStarted: Bool { sentryHandlers.withLock { $0 != nil } }

    /// The Sentry options for ``policy``.
    public func options() -> Options {
        let options = Options()
        options.dsn = Self.dsn
        options.environment = policy.environment
        options.releaseName = policy.release
        options.dist = policy.dist
        options.debug = false
        options.sendDefaultPii = false
        options.tracesSampleRate = 0.0
        options.appHangTimeoutInterval = 8.0
        options.attachStacktrace = true
        options.enableCaptureFailedRequests = false
        // Objective-C exceptions that reach NSApplication's reportException:
        // hook, with their reason and throw stack (main d481d516e520). The
        // SDK also registers NSApplicationCrashOnExceptions, which every
        // channel already registers (cx-r3q, CrashOnExceptions).
        options.enableUncaughtNSExceptionReporting = policy.crashesOnExceptions
        options.enableLogs = false
        let scrubber = SentryEventScrubber()
        let labels = CrashEventLabels(policy: policy)
        options.beforeSend = { event in
            let scrubbed = scrubber.scrub(event)
            labels.apply(to: scrubbed)
            return scrubbed
        }
        options.beforeBreadcrumb = { breadcrumb in scrubber.scrub(breadcrumb) }
        options.beforeSendSpan = { span in scrubber.scrub(span) }
        return options
    }

    /// Starts Sentry when the policy allows it. Call once, on the main
    /// thread, after the run marker's handlers are installed.
    /// - Returns: whether Sentry started.
    @discardableResult
    public func start() -> Bool {
        guard policy.shouldStart, !isStarted else { return false }
        // The main app's startup race (#836): Sentry's init thread reads the
        // environment while the main thread first builds the locale.
        _ = Locale.current
        _ = NSLocale.preferredLanguages
        let appOwned = SignalActions(capturing: Self.appOwnedSignals)
        SentrySDK.start(options: options())
        appOwned.restore()
        let handlers = SignalActions(capturing: Self.fatalSignals)
        sentryHandlers.withLock { $0 = handlers }
        return true
    }

    /// Puts Sentry's fatal-signal handlers back after something reset them
    /// (Chromium's start). Sentry still calls the handlers it saved at
    /// start after its report.
    public func reassertSignalHandlers() {
        sentryHandlers.withLock { $0 }?.restore()
    }

    /// Records a non-fatal product failure (a warning event tagged `failure`)
    /// so a user action that silently did nothing shows up in the crash
    /// telemetry. `message` must hold no user content: it is sent as is.
    public func recordFailure(_ name: String, message: String) {
        guard isStarted else { return }
        SentrySDK.capture(message: "\(name): \(message)") { scope in
            scope.setTag(value: name, key: "failure")
            scope.setLevel(.warning)
        }
    }

    /// Tags the current scope so a crash this process causes on purpose
    /// (`debug.crash.app`, `debug.crash.exception`) can be filtered out.
    public func markDeliberateCrash(_ name: String) {
        guard isStarted else { return }
        SentrySDK.configureScope { scope in scope.setTag(value: name, key: "deliberate_crash") }
    }
}
