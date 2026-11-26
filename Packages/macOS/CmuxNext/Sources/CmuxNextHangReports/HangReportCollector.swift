public import CmuxNextCompat
import Foundation

/// Receives the watchdog's stalls and hangs while hang reports are on, into a ``StallAggregate``
/// that ``HangReportService`` drains into each report.
///
/// ``noteStall(durationNanos:cpuNanos:addresses:)`` runs on the main thread at the end of each
/// stall over the watchdog's threshold: off, it is one atomic load; on, a lock over a few integer
/// adds. Only a stall that earns a stack slot (250 ms and up, among the longest 8) leaves the
/// main thread: its addresses are reduced to ``HangReportFrame``s on a utility task (`resolve`, which
/// reads dyld and the classifier) and kept after that. Sampled stalls wait in a short list for the
/// one resolution job running: the main thread starts a job only when none is pending, so a burst
/// of stalls under load costs it one job, not one per stall. The main thread's part allocates
/// nothing: the waiting list keeps its reserved storage, and a job starts by signalling a dispatch
/// source made once at init, not by creating a task (the main thread hung 2.0 s in that task's
/// allocation and in the list's growth at a stall's end, hq#18810). Nothing here runs while the app is idle.
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
        /// Reserved for ``HangReportCollector/maxPending`` up front, so the main thread's append never grows it.
        var jobs = Pending.reserved()
        var scheduled = false

        static func reserved() -> [(sample: HangSample, addresses: [UInt])] {
            var jobs: [(sample: HangSample, addresses: [UInt])] = []
            jobs.reserveCapacity(HangReportCollector.maxPending)
            return jobs
        }
    }
    /// At most this many samples wait for resolution; more are dropped (only the 8 longest are kept anyway).
    static let maxPending = 16
    /// Runs a resolution job instead of ``wake`` (tests run it inline or hold it).
    private let schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    /// Starts the resolution job on a utility queue: one `or` from the main thread, no allocation.
    /// Nil when `schedule` was given. Under a lock only for `Sendable`: the main thread takes it uncontended.
    private let wake: Mutex<(any DispatchSourceUserDataOr)?>

    /// Makes the value from its parts. `schedule`, when given, runs each resolution job in place of
    /// the default utility queue.
    public init(resolve: @escaping Resolve,
                schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        self.resolve = resolve
        self.schedule = schedule
        let source = schedule == nil
            ? DispatchSource.makeUserDataOrSource(queue: DispatchQueue(label: "com.cmuxterm.app.next.hang-resolve", qos: .utility))
            : nil
        wake = Mutex(source)
        source?.setEventHandler { [weak self] in self?.resolvePending() }
        source?.activate()
    }

    deinit {
        wake.withLock { $0?.cancel() }
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
    /// The copy has storage of its own: one sharing the recorded arrays would make the main thread's
    /// next count copy them (an allocation at a stall's end, hq#18810).
    public func snapshot() -> StallAggregate {
        var copy = StallAggregate()
        aggregate.withLock { copy.merge($0) }
        return copy
    }

    private func keepLater(_ sample: HangSample, addresses: [UInt]) {
        let start = pending.withLock { pending in
            guard pending.jobs.count < Self.maxPending else { return false }
            pending.jobs.append((sample, addresses))
            guard !pending.scheduled else { return false }
            pending.scheduled = true
            return true
        }
        if start { startJob() }
    }

    /// Starts the resolution job: an `or` into the source (no allocation), or a test's scheduler.
    private func startJob() {
        if let schedule {
            schedule { [self] in resolvePending() }
        } else {
            wake.withLock { $0?.or(data: 1) }
        }
    }

    /// Resolves the samples waiting now (off the main thread); samples that came meanwhile go to a next job,
    /// and the last job, finding none, lets the main thread start one again.
    private func resolvePending() {
        // The list's next reserved storage is made here, off the main thread, and swapped in.
        var jobs = Pending.reserved()
        pending.withLock { pending in
            swap(&jobs, &pending.jobs)
            if jobs.isEmpty { pending.scheduled = false }
        }
        guard !jobs.isEmpty else { return }
        for job in jobs {
            var resolved = job.sample
            resolved.frames = Array(resolve(job.addresses).prefix(HangSample.maxFrames))
            if isEnabled { aggregate.withLock { $0.keep(resolved) } }
        }
        startJob()
    }

    static func milliseconds(_ nanos: UInt64) -> Int { Int(min(nanos / 1_000_000, UInt64(HistogramBucket.maxMs))) }
}
