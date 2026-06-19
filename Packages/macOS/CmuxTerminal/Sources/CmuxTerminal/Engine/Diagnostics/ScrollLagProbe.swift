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
/// non-`Sendable` class. This is a faithful lift; the `DispatchWorkItem`
/// scroll-end timer is preserved here and modernized to an injected-`Clock`
/// cancellable task in a separate commit.
public final class ScrollLagProbe {
    private let thresholdMs: Double = 40
    private let minimumSamples = 8
    private let minimumAverageMs: Double = 12
    private let reportCooldownSeconds: TimeInterval = 300

    private(set) var isScrollingFlag = false
    private var sampleCount = 0
    private var totalMs: Double = 0
    private var maxMs: Double = 0
    private var lastReportUptime: TimeInterval?
    private var scrollEndTimer: DispatchWorkItem?

    private let reportSink: (ScrollLagReport) -> Void

    /// Creates a scroll-lag probe.
    ///
    /// - Parameter reportSink: invoked on the main thread once per scroll
    ///   session whose accumulated lag clears the reporting thresholds. The app
    ///   performs the telemetry opt-in check and Sentry capture inside this
    ///   closure.
    public init(reportSink: @escaping (ScrollLagReport) -> Void) {
        self.reportSink = reportSink
    }

    /// Whether a scroll session is currently in flight.
    public var isScrolling: Bool { isScrollingFlag }

    /// Updates scroll state from a scroll-wheel event's momentum phase, arming
    /// or ending the lag-sampling window.
    public func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end timer
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrollingFlag = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrollingFlag = true
            let timer = DispatchWorkItem { [weak self] in
                self?.endScrollSession()
            }
            scrollEndTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
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
