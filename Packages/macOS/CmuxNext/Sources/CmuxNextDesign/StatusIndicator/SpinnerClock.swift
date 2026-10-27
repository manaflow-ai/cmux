public import Foundation
public import QuartzCore

/// The one time base every loading indicator loop counts its phase from: Unix time modulo the
/// loop's period. Native spinners (``StatusIndicatorLayer``) and the web pages' spinners
/// (webviews `ui/spinnerClock.ts`, from `performance.timeOrigin`) read the same wall clock, so
/// any two spinners on screen, in any process, sit at the same angle at the same moment
/// (Lawrence 2026-10-20: "make sure spinners are synced and spinning in the same direction").
///
/// Tests pass fixed times:
///
/// ```swift
/// let clock = SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000.25 })
/// clock.beginTime(cycle: 1) // 99.75: a quarter of a turn done at media time 100
/// ```
public nonisolated struct SpinnerClock: Sendable {
    /// Now on the Core Animation clock (`CACurrentMediaTime`).
    public var mediaTime: @Sendable () -> CFTimeInterval
    // wall-clock: Unix time is the one clock native and web spinners (`performance.timeOrigin`) share.
    /// Now as seconds since 1970 (`Date().timeIntervalSince1970`).
    public var unixTime: @Sendable () -> TimeInterval

    /// - Parameters:
    ///   - mediaTime: Now on the Core Animation clock.
    ///   - unixTime: Now as seconds since 1970; the phase is counted from it.
    public init(mediaTime: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() },
                // wall-clock: the spinner phase is counted from the Unix time web spinners also read.
                unixTime: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.mediaTime = mediaTime
        self.unixTime = unixTime
    }

    /// The media time a repeating loop of `cycle` seconds begins at so that its phase now is
    /// `unixTime mod cycle`: a loop that starts later, or restarts after its window was hidden,
    /// joins in step with the ones already running.
    /// - Parameter cycle: Seconds of one full cycle (a spinner's turn).
    /// - Returns: A media time at most one cycle in the past.
    public func beginTime(cycle: TimeInterval) -> CFTimeInterval {
        let now = mediaTime()
        guard cycle > 0 else { return now }
        return now - phase(cycle: cycle) * cycle
    }

    /// How far through a `cycle`-second loop the shared clock is now, 0..<1.
    /// - Parameter cycle: Seconds of one full cycle.
    public func phase(cycle: TimeInterval) -> Double {
        guard cycle > 0 else { return 0 }
        let into = unixTime().truncatingRemainder(dividingBy: cycle)
        return (into < 0 ? into + cycle : into) / cycle
    }
}
