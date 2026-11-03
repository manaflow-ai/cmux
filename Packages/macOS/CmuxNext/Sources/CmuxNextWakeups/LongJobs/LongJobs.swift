public import Foundation
public import Observation

/// The app's one long-jobs registry (plans/cmux-next/long-jobs-DESIGN.md): the jobs of every
/// machine's daemon (``daemonJobs``, which the composition root points at the machines' daemon
/// services) merged with the app's own (``begin(kind:title:blocks:detail:total:unit:)``). The
/// window's connecting state, the Activity indicator and its popover read ``all``; an app job
/// that ends leaves the list in the same turn.
///
/// Built once in the composition root (AppServices) and passed to whoever registers work.
@MainActor
@Observable
public final class LongJobs {
    /// The app's own running jobs, oldest first.
    public private(set) var appJobs: [LongJob] = []
    /// Every machine's daemon jobs (startup restore jobs while a daemon restores, then its
    /// `jobs-list` / `jobs-changed`). Read inside ``all``, so an observer of ``all`` follows the
    /// daemon services it reads too.
    @ObservationIgnored public var daemonJobs: @MainActor () -> [LongJob] = { [] }
    @ObservationIgnored private var serial: UInt64 = 0
    @ObservationIgnored private let now: @Sendable () -> Date

    /// `now` stamps app jobs (tests pass a fixed clock).
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Every running job: the daemons' first (they are what blocks startup), then the app's, each
    /// oldest first.
    public var all: [LongJob] {
        daemonJobs().sorted { $0.startedMs < $1.startedMs } + appJobs
    }

    /// Whether any job runs now.
    public var isEmpty: Bool { all.isEmpty }

    /// Registers an app job and returns its handle; the job shows until ``LongJobHandle/end()``.
    /// `kind` is a stable dotted id (``LongJob/displayTitle`` localizes the known ones); `title` is
    /// the fallback for a kind the app has no text for (nil: the kind).
    public func begin(kind: String, title: String? = nil, blocks: [LongJob.Block] = [.none], detail: String? = nil,
                      total: UInt64? = nil, unit: String? = nil) -> LongJobHandle {
        serial += 1
        let stamp = Self.milliseconds(now())
        let job = LongJob(id: "app.\(kind):\(serial)", kind: kind, title: title ?? kind, detail: detail, done: total.map { _ in 0 },
                          total: total, unit: unit, startedMs: stamp, updatedMs: stamp, blocks: blocks)
        appJobs.append(job)
        return LongJobHandle(id: job.id, jobs: self)
    }

    /// Runs `work` as an app job that ends when `work` returns or throws.
    public func run<T>(kind: String, title: String? = nil, blocks: [LongJob.Block] = [.none],
                       _ work: (LongJobHandle) async throws -> T) async rethrows -> T {
        let handle = begin(kind: kind, title: title, blocks: blocks)
        defer { handle.end() }
        return try await work(handle)
    }

    func update(_ id: String, _ change: (inout LongJob) -> Void) {
        guard let index = appJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = appJobs[index]
        change(&job)
        job.updatedMs = Self.milliseconds(now())
        guard job != appJobs[index] else { return }
        appJobs[index] = job
    }

    func end(_ id: String) {
        appJobs.removeAll { $0.id == id }
    }

    nonisolated static func milliseconds(_ date: Date) -> Int64 { Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) ?? 0 }
}

/// One app job's handle: progress steps and the end. Ending twice, or updating after the end, does
/// nothing. A handle released without ``end()`` leaves its job listed, so every owner ends it (or
/// uses ``LongJobs/run(kind:title:blocks:_:)``).
@MainActor
public final class LongJobHandle {
    public let id: String
    private weak var jobs: LongJobs?

    init(id: String, jobs: LongJobs) {
        self.id = id
        self.jobs = jobs
    }

    /// Sets how far the job is; nil keeps the current value. A step with no change is a heartbeat.
    public func progress(done: UInt64? = nil, total: UInt64? = nil, detail: String? = nil) {
        jobs?.update(id) { job in
            if let done { job.done = done }
            if let total { job.total = total }
            if let detail { job.detail = detail }
        }
    }

    /// Sets the progress as a fraction (0...1) of a job with no natural unit.
    public func progress(fraction: Double, detail: String? = nil) {
        let clamped = min(1, max(0, fraction))
        progress(done: UInt64(exactly: (clamped * 1000).rounded()) ?? 0, total: 1000, detail: detail)
    }

    public func end() {
        jobs?.end(id)
        jobs = nil
    }
}
