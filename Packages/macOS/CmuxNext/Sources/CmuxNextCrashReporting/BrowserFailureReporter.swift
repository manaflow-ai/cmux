public import CmuxNextCompat
import Foundation

/// Sends browser failures (a renderer that ended, a main-frame load that
/// failed) to crash reporting, deduplicated: a crash loop sends the 1st,
/// 10th, 100th... failure of each key with its count
/// (``BrowserFailureThrottle``). Cancelled loads (ERR_ABORTED) are never
/// sent (``CmuxNextCompat/BrowserEngineFailure/isReportable``). Does
/// nothing while crash reporting is off (consent, managed policy, DEV build
/// without `CMUX_NEXT_DEV_SENTRY=1`, tests).
///
/// ```swift
/// let failures = BrowserFailureReporter(reporter: services.crashReporting.reporter)
/// cache.cef.onEngineFailure = { failures.note($0) }
/// ```
///
/// Tests pass `isEnabled` and a recording `sink`; the sink runs on the
/// caller, so a test reads what was sent at once.
public final class BrowserFailureReporter: Sendable {
    /// Where a sent failure goes (crash reporting in the app; a recorder in tests).
    public typealias Sink = @Sendable (BrowserFailureEvent) -> Void

    private let isEnabled: @Sendable () -> Bool
    private let sink: Sink
    // Lock carve-out: a synchronous count from the main thread for each
    // failure; an actor hop would add a Task per renderer end.
    private let throttle: Mutex<BrowserFailureThrottle>

    /// Reports to `reporter` while it runs; the event is built and captured off the caller.
    /// - Parameters:
    ///   - reporter: The app's crash reporter.
    ///   - throttle: The dedupe policy.
    public convenience init(reporter: CrashReporter, throttle: BrowserFailureThrottle = BrowserFailureThrottle()) {
        self.init(throttle: throttle, isEnabled: { reporter.isStarted }, sink: { event in
            Task.detached(priority: .utility) { reporter.reportBrowserFailure(event) }  // task-owner: one-shot capture
        })
    }

    /// - Parameters:
    ///   - throttle: The dedupe policy.
    ///   - isEnabled: Whether crash reporting runs now.
    ///   - sink: Receives each sent failure, on the caller's thread.
    public init(throttle: BrowserFailureThrottle = BrowserFailureThrottle(), isEnabled: @escaping @Sendable () -> Bool,
                sink: @escaping Sink) {
        self.throttle = Mutex(throttle)
        self.isEnabled = isEnabled
        self.sink = sink
    }

    /// One browser failure.
    /// - Parameter failure: The failure.
    /// - Returns: The event sent, or nil when it was not reportable, deduplicated or reporting is off.
    @discardableResult
    public func note(_ failure: BrowserEngineFailure) -> BrowserFailureEvent? {
        guard failure.isReportable, isEnabled() else { return nil }
        guard let count = throttle.withLock({ $0.admit(failure.dedupeKey) }) else { return nil }
        let event = BrowserFailureEvent(failure: failure, count: count)
        sink(event)
        return event
    }
}
