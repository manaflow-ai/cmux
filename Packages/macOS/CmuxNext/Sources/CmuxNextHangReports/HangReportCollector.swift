public import CmuxNextCompat
import Foundation

/// Receives the watchdog's stalls and hangs while hang reports are on, into a ``StallAggregate``
/// that ``HangReportService`` drains into each report.
///
/// ``noteStall(durationNanos:cpuNanos:addresses:)`` runs on the main thread at the end of each
/// stall over the watchdog's threshold: off, it is one atomic load; on, a lock over one pure
/// `hang_report_note_stall` call (``HangReportRules``). Only a stall that earns a stack slot
/// (250 ms and up, among the longest 8) leaves the main thread: its addresses are reduced to
/// ``HangReportFrame``s on a utility task (`resolve`, which reads dyld and asks the frame rules)
/// and kept after that. Sampled stalls wait in a short list for the
/// one resolution job running: the main thread starts a job only when none is pending, so a burst
/// of stalls under load costs it one job, not one per stall (a 2.0 s hang inside the job's start,
/// hq#18810). Nothing here runs while the app is idle.
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
    /// Sampled stalls and hangs waiting for the resolution job, and whether one is scheduled.
    private let pending = Mutex(Pending())
    private struct Pending {
        var jobs: [(sample: HangSample, addresses: [UInt])] = []
        var scheduled = false
    }
    /// At most this many samples wait for resolution; more are dropped (only the 8 longest are kept anyway).
    static let maxPending = 16
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

    /// One finished stall (main thread, from the watchdog's `onStall`). The rules (`note_stall`)
    /// name its histogram bucket and whether it earns a stack slot; a stall of a hang's length is
    /// only counted (its stack came from `noteHang`, sampled while it ran).
    public func noteStall(durationNanos: UInt64, cpuNanos: UInt64, addresses: [UInt]) {
        guard isEnabled else { return }
        struct Request: Encodable {
            var durationNanos: UInt64
            var cpuNanos: UInt64
            var hasAddresses: Bool
            var stallCount: Int
            var lastStallMs: Int?
        }
        let sample = aggregate.withLock { aggregate -> HangSample? in
            let request = Request(durationNanos: durationNanos, cpuNanos: cpuNanos, hasAddresses: !addresses.isEmpty,
                                  stallCount: aggregate.stalls.count, lastStallMs: aggregate.stalls.last?.durationMs)
            guard let noted = HangReportRules.call("note_stall", request, as: HangReportRules.Noted.self) else { return nil }
            if let bucket = noted.bucket { aggregate.count(bucket: bucket) }
            return noted.sample
        }
        if let sample { keepLater(sample, addresses: addresses) }
    }

    /// One hang still running (watchdog thread, from the watchdog's `onHang`).
    public func noteHang(durationNanos: UInt64, addresses: [UInt]) {
        guard isEnabled, !addresses.isEmpty else { return }
        struct Request: Encodable {
            var durationNanos: UInt64
            var hasAddresses: Bool
            var hangCount: Int
            var lastHangMs: Int?
        }
        let sample = aggregate.withLock { aggregate in
            HangReportRules.call("note_hang", Request(durationNanos: durationNanos, hasAddresses: true, hangCount: aggregate.hangs.count,
                                                      lastHangMs: aggregate.hangs.last?.durationMs), as: HangReportRules.Noted.self)?.sample
        }
        if let sample { keepLater(sample, addresses: addresses) }
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
        let start = pending.withLock { pending in
            guard pending.jobs.count < Self.maxPending else { return false }
            pending.jobs.append((sample, addresses))
            guard !pending.scheduled else { return false }
            pending.scheduled = true
            return true
        }
        if start { schedule { [self] in resolvePending() } }
    }

    /// Resolves the samples waiting now (off the main thread); samples that came meanwhile go to a next job,
    /// and the last job, finding none, lets the main thread start one again.
    private func resolvePending() {
        let jobs = pending.withLock { pending in
            let jobs = pending.jobs
            pending.jobs = []
            if jobs.isEmpty { pending.scheduled = false }
            return jobs
        }
        guard !jobs.isEmpty else { return }
        for job in jobs {
            var resolved = job.sample
            resolved.frames = Array(resolve(job.addresses).prefix(HangSample.maxFrames))
            if isEnabled { aggregate.withLock { $0.keep(resolved) } }
        }
        schedule { [self] in resolvePending() }
    }
}
