import Foundation

/// ``ContinuousClock`` time whose sleep is `Task.sleep(nanoseconds:)`.
///
/// The Swift runtime that ships with macOS 15 traps ("Invalid state for
/// non-cancelled sleep task", `TaskSleepDuration.swift`) when a
/// `ContinuousClock` or `Task.sleep(for:)` sleep races with its task's
/// cancellation. Home's pruning, backoff and deadline loops are cancelled
/// while they sleep, so they sleep through this clock; the nanosecond sleep is
/// a separate runtime path without that state machine.
///
/// ```swift
/// let store = HomeStore(source: source, clock: HomeSleepClock())
/// ```
public struct HomeSleepClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock()

    public init() {}

    public var now: Instant { base.now }

    public var minimumResolution: Swift.Duration { base.minimumResolution }

    /// Sleeps until `deadline`, or throws `CancellationError` when the task is cancelled.
    ///
    /// - Parameters:
    ///   - deadline: When to wake.
    ///   - tolerance: Ignored; the nanosecond sleep takes none.
    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: Self.nanoseconds(remaining))
    }

    /// `duration` in whole nanoseconds, clamped to what `Task.sleep(nanoseconds:)` takes.
    static func nanoseconds(_ duration: Swift.Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return .max }
        let (total, overflowed) = whole.addingReportingOverflow(UInt64(max(0, attoseconds) / 1_000_000_000))
        return overflowed ? .max : total
    }
}
