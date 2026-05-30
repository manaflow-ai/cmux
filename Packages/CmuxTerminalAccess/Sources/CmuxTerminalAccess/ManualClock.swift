// SPDX-License-Identifier: MIT

import Foundation

/// Test ``MonotonicClock`` whose time only advances when ``advance(by:)``
/// is called. Thread-safe via a single ``NSLock``.
///
/// Use this in tests instead of ``SystemMonotonicClock`` so timing-
/// dependent behavior (snapshot polling, throttles, rate limits) can
/// be exercised deterministically without sleeping.
///
/// ```swift
/// let clock = ManualClock(start: 0)
/// let poller = SnapshotPoller(tickRate: 100, clock: clock, read: ..., emit: ...)
/// poller.tick()                 // first tick
/// clock.advance(by: 0.02)
/// poller.tick()                 // second tick, 20ms later
/// ```
public final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double

    /// Creates a clock starting at `start` seconds.
    ///
    /// - Parameter start: Initial monotonic time; defaults to `0`.
    public init(start: Double = 0) { self.t = start }

    /// Returns the current monotonic time in seconds.
    public func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return t
    }

    /// Advances the clock by `delta` seconds.
    ///
    /// - Parameter delta: Amount to add to the clock's current time.
    public func advance(by delta: Double) {
        lock.lock(); t += delta; lock.unlock()
    }
}
