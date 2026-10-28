public import CmuxNextTrace
public import Foundation

/// The launch marks of this process (`debug.timings`' `launch_ms_since_process_start`): each name once, in
/// milliseconds since process start. With a startup trace attached (`CMUX_TRACE_STARTUP`) or the slow-launch
/// ring (Nightly hang reports on), each first mark goes to it too, on the trace's clock. A value: its owner keeps it under its own lock (marks come from
/// any thread; the daemon start path runs off main).
public struct LaunchMarks: Sendable {
    /// Every mark so far, in order.
    public private(set) var all: [(name: String, ms: Double)] = []
    /// The startup trace the marks go to, if one is attached.
    public private(set) var trace: StartupTrace?
    /// The slow-launch ring the marks go to, if one is attached (Nightly hang reports on, p08-startup-111).
    public private(set) var ring: StartupTrace.SlowLaunchRing?

    public init() {}

    /// Sends every later first mark to `trace` too, after a `process_start` mark at `processStart`'s trace-clock
    /// time. Call it before the first mark.
    public mutating func attach(_ trace: StartupTrace, processStart: LaunchClock.Instant) {
        self.trace = trace
        trace.mark("process_start", at: processStart.uptimeNanos)
    }

    /// Sends every later first mark to `ring` too, after a `process_start` mark at `processStart`'s trace-clock
    /// time. Call it before the first mark.
    public mutating func attach(ring: StartupTrace.SlowLaunchRing, processStart: LaunchClock.Instant) {
        self.ring = ring
        ring.mark("process_start", at: processStart.uptimeNanos)
    }

    /// Records `name` at `date` unless it was recorded before. Returns its milliseconds since `processStart`
    /// the first time, nil after; the caller sends the first record to the trace with
    /// ``forward(_:at:to:pairedWith:)``, outside its lock.
    public mutating func record(_ name: String, at date: Date, processStart: Date) -> Double? {
        guard !all.contains(where: { $0.name == name }) else { return nil }
        let ms = date.timeIntervalSince(processStart) * 1_000
        all.append((name, ms))
        return ms
    }

    /// Sends a first mark to `trace` and `ring` (nil: none attached), on the trace clock through `pairing`
    /// (``uptimeNanos(of:pairedWith:)``).
    public static func forward(_ name: String, at date: Date, to trace: StartupTrace?, ring: StartupTrace.SlowLaunchRing? = nil,
                               pairedWith pairing: LaunchClock.Instant) {
        guard trace != nil || ring != nil else { return }
        let nanos = uptimeNanos(of: date, pairedWith: pairing)
        trace?.mark(name, at: nanos)
        ring?.mark(name, at: nanos)
    }

    /// `date` on the trace clock (``TraceClock``, `CLOCK_UPTIME_RAW` nanoseconds): `pairing`'s uptime moved by
    /// how far `date` is from `pairing`'s wall time, before or after it; a time before uptime 0 is 0.
    ///
    /// Every mark of a launch takes the same `pairing`, read once (the process start,
    /// ``LaunchClock/processStart()``), as Chrome's `StartupTimeToTimeTicks` reads its `time_base` and
    /// `trace_ticks_base` once into statics (components/startup_metric_utils/common/startup_metric_utils.cc).
    /// So a mark's trace-clock time depends only on its date and that one read: a wall-clock step after the
    /// pairing does not move a mark, whenever it is converted.
    public static func uptimeNanos(of date: Date, pairedWith pairing: LaunchClock.Instant) -> UInt64 {
        let pairedDate = Date(timeIntervalSince1970: TimeInterval(pairing.wallNanos) / 1e9)
        let uptimeNanos = Double(pairing.uptimeNanos) + (date.timeIntervalSince(pairedDate) * 1e9).rounded()
        guard uptimeNanos > 0 else { return 0 }
        return uptimeNanos < 0x1p64 ? UInt64(uptimeNanos) : .max
    }
}
