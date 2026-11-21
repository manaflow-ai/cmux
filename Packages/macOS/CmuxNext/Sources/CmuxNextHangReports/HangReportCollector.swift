public import CmuxNextCompat
import Foundation

/// Receives the watchdog's stalls and hangs while hang reports are on, into a ``StallAggregate``
/// that ``HangReportService`` drains into each report.
///
/// ``noteStall(durationNanos:cpuNanos:addresses:)`` runs on the main thread at the end of each
/// stall over the watchdog's threshold: off, it is one atomic load; on, a lock over a few integer
/// adds. Only a stall that earns a stack slot (250 ms and up, among the longest 8) leaves the
/// main thread: its addresses are reduced to ``HangReportFrame``s on a utility task (`resolve`, which
/// reads dyld and the classifier) and kept after that. Nothing here runs while the app is idle.
///
/// ```swift
/// let collector = HangReportCollector(resolve: { addresses in frames(for: addresses) })
/// watchdog.onStall = { collector.noteStall(durationNanos: $0.nanos, cpuNanos: $0.cpuNanos, addresses: $0.addresses) }
/// ```
public final class HangReportCollector: Sendable {
    /// Turns return addresses (innermost first) into report frames. Called off the main thread.
    public typealias Resolve = @Sendable ([UInt]) -> [HangReportFrame]

    private let enabled = Atomic<Bool>(false)
    // Lock carve-out: a synchronous count from the main thread's run-loop observer at a stall's
    // end; an actor would add a Task and a hop per stall.
    private let aggregate = Mutex(StallAggregate())
    private let resolve: Resolve
    /// Runs a resolution job; the default is a detached utility task. Tests run it inline.
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Makes the value from its parts.
    public init(resolve: @escaping Resolve,
                schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { job in
                    // task-owner: one short resolution per sampled stall; nothing to cancel.
                    Task.detached(priority: .utility) { job() }
                }) {
        self.resolve = resolve
        self.schedule = schedule
    }

    /// Whether stalls are recorded.
    public var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    /// Turns recording on or off; off drops what was recorded.
    public func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
        if !on { _ = drain() }
    }

    /// One finished stall (main thread, from the watchdog's `onStall`).
    public func noteStall(durationNanos: UInt64, cpuNanos: UInt64, addresses: [UInt]) {
        guard isEnabled else { return }
        let ms = Self.milliseconds(durationNanos)
        // A stall of a hang's length is only counted: its stack came from `noteHang`, sampled
        // while it ran, which shows where it was stuck rather than where it started.
        let sample = aggregate.withLock { aggregate in
            aggregate.count(durationMs: ms)
            return !addresses.isEmpty && ms < StallAggregate.hangMs && aggregate.wantsStallSample(durationMs: ms)
        }
        guard sample else { return }
        keepLater(HangSample(source: .watchdog, kind: .stall, durationMs: ms, cpuMs: Self.milliseconds(cpuNanos), frames: []),
                  addresses: addresses)
    }

    /// One hang still running (watchdog thread, from the watchdog's `onHang`).
    public func noteHang(durationNanos: UInt64, addresses: [UInt]) {
        guard isEnabled, !addresses.isEmpty else { return }
        let ms = Self.milliseconds(durationNanos)
        guard aggregate.withLock({ $0.wantsHangSample(durationMs: ms) }) else { return }
        keepLater(HangSample(source: .watchdog, kind: .hang, durationMs: ms, frames: []), addresses: addresses)
    }

    /// ``noteStall(durationNanos:cpuNanos:addresses:)`` with the watchdog's durations.
    public func noteStall(duration: Duration, cpu: Duration, addresses: [UInt]) {
        noteStall(durationNanos: Self.nanos(duration), cpuNanos: Self.nanos(cpu), addresses: addresses)
    }

    /// ``noteHang(durationNanos:addresses:)`` with the watchdog's duration.
    public func noteHang(duration: Duration, addresses: [UInt]) {
        noteHang(durationNanos: Self.nanos(duration), addresses: addresses)
    }

    /// A non-negative duration in nanoseconds, clamped.
    static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(clamping: max(Int64(0), seconds)) &* 1_000_000_000 &+ UInt64(clamping: max(Int64(0), attoseconds / 1_000_000_000))
    }

    /// Takes what was recorded and starts over.
    public func drain() -> StallAggregate {
        aggregate.withLock { aggregate in
            let taken = aggregate
            aggregate = StallAggregate()
            return taken
        }
    }

    /// Adds a saved aggregate (the previous launch's) to what is recorded now.
    public func merge(_ saved: StallAggregate) {
        guard isEnabled, !saved.isEmpty else { return }
        aggregate.withLock { $0.merge(saved) }
    }

    /// A copy of what is recorded, for a preview.
    public func snapshot() -> StallAggregate { aggregate.withLock { $0 } }

    private func keepLater(_ sample: HangSample, addresses: [UInt]) {
        let resolve = resolve
        schedule { [self] in
            var resolved = sample
            resolved.frames = Array(resolve(addresses).prefix(HangSample.maxFrames))
            guard isEnabled else { return }
            aggregate.withLock { $0.keep(resolved) }
        }
    }

    static func milliseconds(_ nanos: UInt64) -> Int { Int(min(nanos / 1_000_000, UInt64(HistogramBucket.maxMs))) }
}
