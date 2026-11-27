public import Foundation
public import QuartzCore

/// The one time base every loading indicator loop counts its phase from: Unix time modulo the
/// loop's period, read as the media clock on one Unix offset per process (``processEpoch``).
/// Native spinners (``StatusIndicatorLayer``) and the web pages' spinners (webviews
/// `ui/spinnerClock.ts`, from `performance.timeOrigin`) count from the wall clock, so spinners in
/// one process always sit at the same angle, and a page and the app chrome do until a sleep moves
/// one's offset from the other's (Lawrence 2026-10-20: "make sure spinners are synced and spinning
/// in the same direction").
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
    /// Now as seconds since 1970: by default the media clock on one offset per process.
    public var unixTime: @Sendable () -> TimeInterval

    /// Unix time minus media time, read once per process. The media clock stops while the Mac
    /// sleeps and Unix time does not, so reading both afresh for every spinner put one started
    /// after a sleep out of step with one still turning from before it (Leo 2026-11-01, on two
    /// working spinners side by side: "why did you desync these"). Counted from this one offset,
    /// every spinner in the process keeps one phase however long it ran.
    static let processEpoch: TimeInterval = Date().timeIntervalSince1970 - CACurrentMediaTime()

    /// - Parameters:
    ///   - mediaTime: Now on the Core Animation clock.
    ///   - unixTime: Now as seconds since 1970; the phase is counted from it. Nil reads `mediaTime`
    ///     on the process's one Unix offset (``processEpoch``).
    public init(mediaTime: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() },
                unixTime: (@Sendable () -> TimeInterval)? = nil) {
        self.mediaTime = mediaTime
        self.unixTime = unixTime ?? { mediaTime() + SpinnerClock.processEpoch }
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
