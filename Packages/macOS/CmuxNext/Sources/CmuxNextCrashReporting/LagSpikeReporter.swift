public import Foundation
import CmuxNextCompat
import Darwin
import Sentry

/// Sends main-thread lag spikes (finished stalls of ``LagSpikeRateLimiter``
/// minimum length and longer) to crash reporting, rate-limited.
///
/// The watchdog calls ``noteStall(duration:cpu:addresses:)`` on the main
/// thread when a stall ends. That call only checks the limiter (a lock over
/// a few integers) and, for an admitted spike, reads ``contextProvider``;
/// the event is built and sent on a detached utility task, off the main
/// thread. Does nothing while crash reporting is off (consent, managed
/// policy, DEV build without `CMUX_NEXT_DEV_SENTRY=1`, tests).
///
/// ```swift
/// let lag = LagSpikeReporter(reporter: services.crashReporting.reporter)
/// control.watchdog.onStall = { record in
///     lag.noteStall(duration: record.duration, cpu: record.cpu, addresses: record.addresses)
/// }
/// ```
public final class LagSpikeReporter: Sendable {
    /// `CMUX_NEXT_LAG_REPORT_MS` changes the shortest reported spike
    /// (default 250 ms, at least 50 ms).
    public static let thresholdEnvironmentKey = "CMUX_NEXT_LAG_REPORT_MS"

    /// The sink an admitted spike goes to (crash reporting in the app; a
    /// recorder in tests). Called off the main thread.
    public typealias Sink = @Sendable (LagSpikeEvent) -> Void

    private let isEnabled: @Sendable () -> Bool
    private let sink: Sink
    private let uptime: @Sendable () -> UInt64
    // Lock carve-out: a synchronous admit check from the main thread at the
    // end of a stall; an actor hop would add a Task per stall.
    private let limiter: Mutex<LagSpikeRateLimiter>
    /// Main thread, only for an admitted spike: non-content counts (windows,
    /// workspaces, tabs). Must be cheap.
    private let contextProvider: Mutex<(@Sendable () -> [String: String])?>

    /// Every finished stall's count (also the ones too short to send), when set.
    private let summary: StallSummaryRecorder?

    /// Reports to `reporter` when it runs; counts every stall in its ``CrashReporter/stallSummary``.
    public convenience init(reporter: CrashReporter,
                            limiter: LagSpikeRateLimiter = LagSpikeRateLimiter(minimumNanos: LagSpikeReporter.environmentMinimumNanos())) {
        self.init(limiter: limiter, isEnabled: { reporter.isStarted }, summary: reporter.stallSummary, sink: { reporter.reportLagSpike($0) })
    }

    /// Test seam: an explicit enabled check, summary, sink and monotonic clock.
    public init(limiter: LagSpikeRateLimiter, isEnabled: @escaping @Sendable () -> Bool, summary: StallSummaryRecorder? = nil,
                sink: @escaping Sink, uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.limiter = Mutex(limiter)
        self.isEnabled = isEnabled
        self.summary = summary
        self.sink = sink
        self.uptime = uptime
        self.contextProvider = Mutex(nil)
    }

    /// Sets the context read for each admitted spike (main thread).
    public func setContextProvider(_ provider: (@Sendable () -> [String: String])?) {
        contextProvider.withLock { $0 = provider }
    }

    /// One finished main-thread stall.
    /// - Returns: whether it was admitted (sent).
    @discardableResult
    public func noteStall(duration: Duration, cpu: Duration, addresses: [UInt]) -> Bool {
        guard isEnabled() else { return false }
        let nanos = UInt64(clamping: max(Int64(0), duration.components.seconds) * 1_000_000_000
            + duration.components.attoseconds / 1_000_000_000)
        summary?.record(.stall(nanos: nanos))
        let now = uptime()
        guard limiter.withLock({ $0.admit(durationNanos: nanos, nowNanos: now) }) else { return false }
        summary?.record(.spikeSent)
        let context = contextProvider.withLock { $0 }?() ?? [:]
        let event = LagSpikeEvent(duration: duration, cpu: cpu, addresses: addresses, context: context)
        let sink = self.sink
        Task.detached(priority: .utility) { sink(event) }
        return true
    }

    /// The minimum from ``thresholdEnvironmentKey``, else 250 ms.
    public static func environmentMinimumNanos(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt64 {
        let ms = environment[thresholdEnvironmentKey].flatMap(Int.init) ?? 250
        return UInt64(max(ms, 50)) * 1_000_000
    }
}

extension CrashReporter {
    /// Sends a finished main-thread lag spike. Call off the main thread
    /// (builds debug-image metadata). Does nothing when crash reporting is off.
    public nonisolated func reportLagSpike(_ spike: LagSpikeEvent) {
        guard isStarted else { return }
        SentrySDK.capture(event: spike.event())
    }
}
