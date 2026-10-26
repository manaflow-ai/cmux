public import CmuxNextTrace
public import Foundation

/// The launch marks of this process (`debug.timings`' `launch_ms_since_process_start`): each name once, in
/// milliseconds since process start. With a startup trace attached (`CMUX_TRACE_STARTUP`), each first mark
/// goes to it too, on the trace's clock. A value: its owner keeps it under its own lock (marks come from
/// any thread; the daemon start path runs off main).
public struct LaunchMarks: Sendable {
    /// Every mark so far, in order.
    public private(set) var all: [(name: String, ms: Double)] = []
    /// The startup trace the marks go to, if one is attached.
    public private(set) var trace: StartupTrace?

    public init() {}

    /// Sends every later first mark to `trace` too, after a `process_start` mark at `processStart`. Call it
    /// before the first mark.
    public mutating func attach(_ trace: StartupTrace, processStart: Date) {
        self.trace = trace
        trace.mark("process_start", at: Self.uptimeNanos(of: processStart))
    }

    /// Records `name` at `date` unless it was recorded before. Returns its milliseconds since `processStart`
    /// the first time, nil after; the caller sends the first record to the trace with ``forward(_:at:)``,
    /// outside its lock.
    public mutating func record(_ name: String, at date: Date, processStart: Date) -> Double? {
        guard !all.contains(where: { $0.name == name }) else { return nil }
        let ms = date.timeIntervalSince(processStart) * 1_000
        all.append((name, ms))
        return ms
    }

    /// Sends a first mark to `trace` (nil: no trace attached).
    public static func forward(_ name: String, at date: Date, to trace: StartupTrace?, clock: LaunchClock = LaunchClock()) {
        trace?.mark(name, at: uptimeNanos(of: date, clock: clock))
    }

    /// `date` on the trace clock (``TraceClock``, `CLOCK_UPTIME_RAW` nanoseconds), through one paired read of
    /// both clocks (``LaunchClock/now()``), as Chrome's `StartupTimeToTimeTicks` moves a `base::Time` onto
    /// `TimeTicks` (components/startup_metric_utils/common/startup_metric_utils.cc). A date after the pairing
    /// read is now; one before uptime 0 is 0.
    public static func uptimeNanos(of date: Date, clock: LaunchClock = LaunchClock()) -> UInt64 {
        let wallNanos = (max(0, date.timeIntervalSince1970) * 1e9).rounded()
        return LaunchClock.uptimeNanos(ofWallNanos: wallNanos < 0x1p64 ? UInt64(wallNanos) : .max, pairedWith: clock.now())
    }
}
