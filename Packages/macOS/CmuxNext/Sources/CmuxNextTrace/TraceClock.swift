import Darwin

/// The one trace clock: `CLOCK_UPTIME_RAW` nanoseconds, the clock of every ring record
/// (plans/cmux-next/trace.md, "Release trace ring v1").
///
/// `CLOCK_UPTIME_RAW` is `mach_absolute_time` in nanoseconds. It stops while the Mac sleeps. It is the clock
/// of `NSEvent.timestamp`, `ProcessInfo.systemUptime`, `CACurrentMediaTime()`, `SuspendingClock` and
/// Chromium's `base::TimeTicks` (`base/time/time_mac.mm`), so those convert with arithmetic only.
///
/// `ContinuousClock` counts sleep (`CLOCK_MONOTONIC_RAW`, `mach_continuous_time`): its offset to this clock
/// grows by every sleep. A `ContinuousClock.Instant` converts only through a ``ContinuousStamp`` read when
/// the instant was captured, never through an offset read later.
///
/// ```swift
/// let clock = TraceClock()
/// let t = clock.nowNanos()
/// let keyNanos = TraceClock.nanos(fromUptimeSeconds: event.timestamp)
/// ```
public nonisolated struct TraceClock: Sendable {
    /// The reads of the two clocks, injected by tests.
    public struct Reader: Sendable {
        /// `CLOCK_UPTIME_RAW` nanoseconds now.
        public let uptimeNanos: @Sendable () -> UInt64
        /// `ContinuousClock.now`.
        public let continuousNow: @Sendable () -> ContinuousClock.Instant

        public init(
            uptimeNanos: @escaping @Sendable () -> UInt64,
            continuousNow: @escaping @Sendable () -> ContinuousClock.Instant
        ) {
            self.uptimeNanos = uptimeNanos
            self.continuousNow = continuousNow
        }
    }

    /// A `ContinuousClock` instant and the `CLOCK_UPTIME_RAW` time read with it.
    ///
    /// Take it where the code took `ContinuousClock.now`, keep ``continuous`` for duration arithmetic, and
    /// convert instants near it with ``TraceClock/nanos(_:pairedWith:)``.
    public struct ContinuousStamp: Sendable, Equatable {
        /// The `ContinuousClock` reading.
        public let continuous: ContinuousClock.Instant
        /// `CLOCK_UPTIME_RAW` nanoseconds at the same moment.
        public let uptimeNanos: UInt64
        /// The nanoseconds between the two uptime reads around the continuous read. ``uptimeNanos`` is their
        /// midpoint, so it is off by at most half of this; a caller that needs a tight pairing reads again.
        public let readWidthNanos: UInt64

        public init(continuous: ContinuousClock.Instant, uptimeNanos: UInt64, readWidthNanos: UInt64 = 0) {
            self.continuous = continuous
            self.uptimeNanos = uptimeNanos
            self.readWidthNanos = readWidthNanos
        }
    }

    /// `nil` reads the system clocks directly, with no closure call on the trace write path.
    private let reader: Reader?

    /// The system clocks.
    public init() {
        reader = nil
    }

    /// Clocks read through `reader` (tests).
    public init(reader: Reader) {
        self.reader = reader
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds now: a commpage read, no system call.
    public func nowNanos() -> UInt64 {
        guard let reader else { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        return reader.uptimeNanos()
    }

    /// Reads `ContinuousClock.now` between two uptime reads and pairs it with their midpoint, keeping the
    /// reads' width as the pairing's error bound.
    public func continuousStamp() -> ContinuousStamp {
        let before = nowNanos()
        let continuous = reader?.continuousNow() ?? ContinuousClock.now
        let after = nowNanos()
        let width = after &- before
        return ContinuousStamp(continuous: continuous, uptimeNanos: before &+ width / 2, readWidthNanos: width)
    }

    /// Uptime seconds (`NSEvent.timestamp`, `ProcessInfo.systemUptime`) as trace nanoseconds, rounded.
    /// A negative or NaN time is 0; a time past the `UInt64` range is `UInt64.max`.
    public static func nanos(fromUptimeSeconds seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        let nanos = (seconds * 1e9).rounded()
        return nanos < 0x1p64 ? UInt64(nanos) : .max
    }

    /// `CACurrentMediaTime()` seconds as trace nanoseconds: the same clock as uptime seconds.
    public static func nanos(fromMediaTime seconds: Double) -> UInt64 {
        nanos(fromUptimeSeconds: seconds)
    }

    /// A `ContinuousClock` instant as trace nanoseconds, through the stamp read when it was captured.
    ///
    /// Exact while no sleep falls between `instant` and `stamp`. A stamp read before a sleep is off by the
    /// whole sleep for an instant after it, which is why no converter takes a bare instant. A result
    /// before uptime 0 is 0.
    public static func nanos(_ instant: ContinuousClock.Instant, pairedWith stamp: ContinuousStamp) -> UInt64 {
        let (seconds, attoseconds) = stamp.continuous.duration(to: instant).components
        // The wrapping operators wrap only for offsets past 292 years.
        let offset = seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
        return UInt64(clamping: Int64(clamping: stamp.uptimeNanos) &+ offset)
    }
}
