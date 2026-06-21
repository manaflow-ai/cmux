internal import Foundation

/// Accumulates per-tick terminal render lag during a scroll session and reports
/// sustained lag once the session ends.
///
/// Replaces the scroll-lag state (`isScrolling`, the sample accumulators and
/// thresholds, `lastScrollLagReportUptime`, `scrollEndTimer`) and the
/// `markScrollActivity(hasMomentum:momentumEnded:)` / `endScrollSession()` /
/// `shouldCaptureScrollLagEvent(...)` helpers that lived on the `GhosttyApp` god
/// type. It is a self-contained telemetry probe with no view coupling, so it
/// folds into the engine as its own service. Telemetry submission stays
/// app-side: when a session clears the reporting thresholds the probe hands a
/// `ScrollLagReport` to the injected `reportSink`, which performs the (gated)
/// Sentry capture.
///
/// Isolation design: `markScrollActivity` is driven from `scrollWheel(with:)`
/// (main-thread AppKit) and `recordTickSample` from `GhosttyApp.tick()` (the
/// main-queue tick). The legacy `GhosttyApp` was a non-isolated, non-`Sendable`
/// class whose scroll-lag state was touched only from the main thread by
/// convention; this lift preserves that exact isolation as a plain non-isolated,
/// non-`Sendable` class.
///
/// Scroll-end debounce: the legacy mouse-wheel path used a `DispatchWorkItem`
/// scheduled via `DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)` and
/// cancelled on the next scroll. This type instead schedules a cancellable
/// `Task` that sleeps on an injected `Clock` and then re-enters the main actor
/// to end the session. Cancellation is by guard, not by check: the post-sleep
/// closure re-reads `isScrollingFlag` and a per-arm `generation`, so a stale
/// fire is an idempotent no-op even if the cancel races. The only observable
/// difference from the legacy timer is the scroll-end debounce timing (a
/// monotonic `ContinuousClock` interval rather than `asyncAfter`'s wall-clock
/// deadline); the injected clock makes that interval test-controllable.
public final class ScrollLagProbe {
    private let thresholdMs: Double = 40
    private let minimumSamples = 8
    private let minimumAverageMs: Double = 12
    private let reportCooldownSeconds: TimeInterval = 300
    private let scrollEndDebounce: Duration = .milliseconds(150)

    private(set) var isScrollingFlag = false
    private var sampleCount = 0
    private var totalMs: Double = 0
    private var maxMs: Double = 0
    private var lastReportUptime: TimeInterval?
    private var scrollEndTask: Task<Void, Never>?
    /// Bumped each time the debounce is (re)armed; the delayed closure ends the
    /// session only when its captured value still matches, absorbing stale fires.
    private var scrollEndGeneration = 0

    private let clock: any Clock<Duration>
    private let reportSink: (ScrollLagReport) -> Void

    /// Creates a scroll-lag probe.
    ///
    /// - Parameters:
    ///   - clock: the clock the mouse-wheel scroll-end debounce sleeps on
    ///     (`ContinuousClock` in production; tests inject a controllable clock).
    ///   - reportSink: invoked on the main thread once per scroll session whose
    ///     accumulated lag clears the reporting thresholds. The app performs the
    ///     telemetry opt-in check and Sentry capture inside this closure.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        reportSink: @escaping (ScrollLagReport) -> Void
    ) {
        self.clock = clock
        self.reportSink = reportSink
    }

    /// Whether a scroll session is currently in flight.
    public var isScrolling: Bool { isScrollingFlag }

    /// Awaits the pending mouse-wheel scroll-end debounce task, if any. Test-only
    /// hook so a suite can deterministically observe the post-debounce state.
    ///
    /// `@MainActor` so a main-actor caller (the probe is main-thread-confined by
    /// contract, so its tests run on `@MainActor`) can await it without sending
    /// the non-`Sendable` probe across an isolation boundary (`#SendingRisksDataRace`).
    /// Awaiting the task's `value` only suspends; the debounce body itself already
    /// hops onto the main actor before touching `self`.
    @MainActor
    func awaitPendingScrollEnd() async {
        await scrollEndTask?.value
    }

    /// Updates scroll state from a scroll-wheel event's momentum phase, arming
    /// or ending the lag-sampling window.
    public func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end debounce.
        scrollEndTask?.cancel()
        scrollEndTask = nil
        scrollEndGeneration &+= 1

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrollingFlag = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrollingFlag = true
            let generation = scrollEndGeneration
            let clock = clock
            let debounce = scrollEndDebounce
            // SAFETY: this probe is main-thread-confined by contract (the legacy
            // `GhosttyApp` accessed all scroll-lag state only from main, and the
            // legacy debounce used `DispatchQueue.main.asyncAfter`). The type is
            // deliberately non-isolated and non-`Sendable` to mirror that, and
            // its forwarders on the non-isolated `GhosttyApp` god type are also
            // non-isolated, so it must NOT become `@MainActor`. The debounce
            // `Task` is `@MainActor`-isolated so the self-mutating end runs on
            // main synchronously before the task completes (matching the legacy
            // timer, which fired on main, and keeping `awaitPendingScrollEnd`
            // deterministic). `weakSelf` is captured as `nonisolated(unsafe)` so
            // that bridging the non-isolated caller's `self` into the main-actor
            // task body does not trip Swift 6.1's region-isolation check; the
            // contract guarantees the access stays on main, and the body re-reads
            // the per-arm `generation` so a stale fire is an idempotent no-op.
            nonisolated(unsafe) weak let weakSelf = self
            scrollEndTask = Task { @MainActor in
                try? await clock.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                guard let weakSelf, weakSelf.scrollEndGeneration == generation else { return }
                weakSelf.endScrollSession()
            }
        }
    }

    /// Records one tick's render duration while a scroll session is active.
    public func recordTickSample(elapsedMs: Double) {
        guard isScrollingFlag else { return }
        sampleCount += 1
        totalMs += elapsedMs
        maxMs = max(maxMs, elapsedMs)
    }

    private func endScrollSession() {
        guard isScrollingFlag else { return }
        isScrollingFlag = false

        // Report accumulated lag stats if any exceeded threshold
        if sampleCount > 0 {
            let avgLag = totalMs / Double(sampleCount)
            let maxLag = maxMs
            let samples = sampleCount
            let threshold = thresholdMs
            let nowUptime = ProcessInfo.processInfo.systemUptime
            if Self.shouldCaptureScrollLagEvent(
                samples: samples,
                averageMs: avgLag,
                maxMs: maxLag,
                thresholdMs: threshold,
                minimumSamples: minimumSamples,
                minimumAverageMs: minimumAverageMs,
                nowUptime: nowUptime,
                lastReportedUptime: lastReportUptime,
                cooldown: reportCooldownSeconds
            ) {
                reportSink(
                    ScrollLagReport(
                        samples: samples,
                        averageMs: avgLag,
                        maxMs: maxLag,
                        thresholdMs: threshold
                    )
                )
                lastReportUptime = nowUptime
            }
            // Reset stats
            sampleCount = 0
            totalMs = 0
            maxMs = 0
        }
    }

    /// Pure decision: whether a finished scroll session's accumulated lag stats
    /// warrant a telemetry report, given the minimum-sample/average gates and
    /// the per-session cooldown. `nonisolated static` and total so it can be
    /// unit tested in isolation without constructing a probe.
    nonisolated static func shouldCaptureScrollLagEvent(
        samples: Int,
        averageMs: Double,
        maxMs: Double,
        thresholdMs: Double,
        minimumSamples: Int = 8,
        minimumAverageMs: Double = 12,
        nowUptime: TimeInterval,
        lastReportedUptime: TimeInterval?,
        cooldown: TimeInterval = 300
    ) -> Bool {
        guard samples >= minimumSamples else { return false }
        guard averageMs.isFinite, maxMs.isFinite, thresholdMs.isFinite, nowUptime.isFinite, cooldown.isFinite else {
            return false
        }
        guard averageMs >= minimumAverageMs else { return false }
        guard maxMs > thresholdMs else { return false }
        if let lastReportedUptime, nowUptime - lastReportedUptime < cooldown {
            return false
        }
        return true
    }
}
