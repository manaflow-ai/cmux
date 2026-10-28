#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Foundation

/// `debug.startup.main_jobs`' payload, built from a ``MainJobCensus/Snapshot`` off the main thread: the main jobs and
/// main turns `startup-queue.py mainjobs` ranks (queue Q11, task template 081). Times are milliseconds since process
/// start.
///
/// - `main_jobs`: one record per job the ring timed (`main_actor`, `main_delivery`, `run_loop_block`, `timer`) that
///   did not spend half its time or more in a StartupScheduler task, its `run_ms` less that task time. `caller` is
///   its enqueuer (``caller(_:kind:)``), or `timer <owner>` for a `DemandTimer` fire and the main-actor jobs it
///   enqueued. Then one record per run-loop callout stretch of its own time (`run_loop_sources`, `run_loop_wake`:
///   the system's callouts, the time no main job and no StartupScheduler task covered; `caller` names the phase).
/// - `main_turns`: each turn of 1 ms or more, its `task` the StartupScheduler main task that covered half of it or
///   more (else null), and its `site` what took most of its time: the longest main job's caller, or a phase.
///   `allowlisted` turns are not Q11's (``defaultAllowlist``).
/// - `main_job_census`: whether the hook ran, and what the bounds dropped.
///
/// ```swift
/// let report = MainJobCensusReport(snapshot) { addresses in symbolicator.frames(for: addresses).map(frame) }
/// let reply = try report.foundationObject()
/// ```
public nonisolated struct MainJobCensusReport: Sendable, Encodable {
    /// One resolved return address.
    public struct Frame: Sendable, Equatable {
        /// The image's file name.
        public var image: String?
        /// The demangled function name, nil when the image has none for it.
        public var symbol: String?
        /// The offset from the image's header.
        public var imageOffset: UInt?

        public init(image: String?, symbol: String?, imageOffset: UInt?) {
            self.image = image
            self.symbol = symbol
            self.imageOffset = imageOffset
        }
    }

    public struct JobRecord: Sendable, Equatable, Encodable {
        public var caller: String
        /// `main_actor`, `main_delivery`, `run_loop_block`, `timer`, `run_loop_sources` or `run_loop_wake`.
        public var kind: String
        /// The QoS class name; nil for a run-loop stretch.
        public var priority: String?
        public var enqueuedMs: Double
        public var runMs: Double

        private enum CodingKeys: String, CodingKey {
            case caller, kind, priority
            case enqueuedMs = "enqueued_ms", runMs = "run_ms"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(caller, forKey: .caller)
            try container.encode(kind, forKey: .kind)
            try container.encode(priority, forKey: .priority)
            try container.encode(enqueuedMs, forKey: .enqueuedMs)
            try container.encode(runMs, forKey: .runMs)
        }
    }

    public struct TurnRecord: Sendable, Equatable, Encodable {
        public var startMs: Double
        public var durationMs: Double
        public var task: String?
        public var allowlisted: Bool
        public var site: String
        public var jobs: Int
        public var jobMs: Double

        private enum CodingKeys: String, CodingKey {
            case task, allowlisted, site, jobs
            case startMs = "start_ms", durationMs = "duration_ms", jobMs = "job_ms"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(startMs, forKey: .startMs)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(task, forKey: .task)
            try container.encode(allowlisted, forKey: .allowlisted)
            try container.encode(site, forKey: .site)
            try container.encode(jobs, forKey: .jobs)
            try container.encode(jobMs, forKey: .jobMs)
        }
    }

    public struct Summary: Sendable, Equatable, Encodable {
        public var armed = true
        /// ``MainJobRing/HookState``'s name: `installed`, `missing` or `busy`.
        public var hook: String
        public var frozen: Bool
        public var jobs: Int
        public var pendingJobs: Int
        public var droppedJobs: Int
        public var shortTurns: Int
        public var droppedTurns: Int
        public var droppedSegments: Int

        private enum CodingKeys: String, CodingKey {
            case armed, hook, frozen, jobs
            case pendingJobs = "pending_jobs", droppedJobs = "dropped_jobs", shortTurns = "short_turns"
            case droppedTurns = "dropped_turns", droppedSegments = "dropped_segments"
        }
    }

    /// The sites whose turns are not Q11's: the code outside the run loop is AppKit's event dispatch (the person's
    /// input, which goes first) and the launch's own `main` and `applicationDidFinishLaunching`, which queues Q5,
    /// Q6 and Q7 measure.
    public static let defaultAllowlist: Set<String> = [MainTurnSegments.Phase.outside.rawValue]
    /// What the enqueuer search skips besides ``MainJobRing/enqueueRuntimeImages``: the system's lowest images.
    static let systemImages: Set<String> = ["libsystem_kernel.dylib", "libsystem_platform.dylib", "libsystem_c.dylib"]
    /// The demangled `Task` and `MainActor` members (the mangled ones are ``MainJobRing/enqueueRuntimeSymbolPrefixes``):
    /// `Task.init` is not inlined in a Debug build and would name every `Task { }` of a module as one enqueuer.
    static let runtimeSymbolNames = ["Swift.Task<", "Swift.Task.", "Swift.MainActor."]
    /// The census's own frames between the post and its site: the ring and the posting seams (a classed
    /// ``MainDelivery`` hop posts through the scheduler's `postFromAnyThread` to a `MainRunLoopBlock`).
    static let censusSymbols = ["MainJobRing.", "MainDelivery.", "MainWorkScheduler.postFromAnyThread", "MainRunLoopBlock.", "MainJobCensus."]
    /// The caller of a job whose stack holds no frame of its enqueuer.
    static let unknownCaller = "unknown"

    public var census: Summary
    public var mainJobs: [JobRecord]
    public var mainTurns: [TurnRecord]

    /// - Parameters:
    ///   - symbolize: Resolves one job's return addresses, innermost first (the app: `StackSymbolicator`); called
    ///     once per distinct stack.
    ///   - allowlist: The turn sites that are not Q11's.
    public init(_ snapshot: MainJobCensus.Snapshot, allowlist: Set<String> = defaultAllowlist,
                symbolize: ([UInt]) -> [Frame]) {
        let start = snapshot.processStartNanos
        func ms(_ nanos: UInt64) -> Double { (Double(nanos) / 1_000).rounded() / 1_000 }
        func since(_ nanos: UInt64) -> Double { ms(nanos > start ? nanos - start : 0) }

        let spans = snapshot.tasks.sorted { $0.startNanos < $1.startNanos }
        let tasks = Self.merged(spans.map { (start: $0.startNanos, end: $0.startNanos &+ $0.durationNanos) })
        var resolved: [[UInt]: [Frame]] = [:]
        var callerBySlot: [Int: String] = [:]
        var jobs: [JobRecord] = []
        jobs.reserveCapacity(snapshot.jobs.count + snapshot.segments.segments.count)
        for job in snapshot.jobs {
            let caller: String
            if let label = job.label {
                caller = "timer \(label)"
            } else {
                let frames = resolved[job.frames] ?? symbolize(job.frames)
                resolved[job.frames] = frames
                caller = Self.caller(frames, kind: job.kind)
            }
            callerBySlot[job.slot] = caller
            // A job that ran a StartupScheduler task for half its time or more is that task's (Q11 is the rest).
            let inTasks = Self.covered(tasks, job.runStartNanos, job.runStartNanos &+ job.runNanos)
            guard job.runNanos == 0 || inTasks * 2 < job.runNanos else { continue }
            jobs.append(JobRecord(caller: caller, kind: Self.kindName(job.kind), priority: Self.priorityName(job.priority),
                                  enqueuedMs: since(job.enqueuedNanos), runMs: ms(job.runNanos - inTasks)))
        }
        // A stretch's own time is its wall time less every instant a main job or a scheduler task covered, each once:
        // a task can run inside a job, and a job inside a task.
        let timed = Self.merged(tasks + snapshot.jobs.map { (start: $0.runStartNanos, end: $0.runStartNanos &+ $0.runNanos) })
        for segment in snapshot.segments.segments {
            let end = segment.startNanos &+ segment.elapsedNanos
            let covered = Self.covered(timed, segment.startNanos, end)
            let own = segment.elapsedNanos > covered ? segment.elapsedNanos - covered : 0
            guard own >= snapshot.segments.segmentFloorNanos else { continue }
            jobs.append(JobRecord(caller: segment.phase.rawValue, kind: segment.phase == .wake ? "run_loop_wake" : "run_loop_sources",
                                  priority: nil, enqueuedMs: since(segment.startNanos), runMs: ms(own)))
        }
        mainJobs = jobs

        mainTurns = snapshot.segments.turns.map { turn in
            let task = Self.coveringTask(spans, turn)
            let site = Self.site(of: turn, longestCaller: turn.jobs.longestSlot.flatMap { callerBySlot[$0] })
            return TurnRecord(startMs: since(turn.startNanos), durationMs: ms(turn.durationNanos), task: task,
                              allowlisted: task == nil && allowlist.contains(site), site: site, jobs: turn.jobs.jobs,
                              jobMs: ms(turn.jobs.nanos))
        }
        census = Summary(hook: snapshot.hook.rawValue, frozen: snapshot.frozen, jobs: snapshot.jobs.count,
                         pendingJobs: snapshot.pendingJobs, droppedJobs: snapshot.droppedJobs,
                         shortTurns: snapshot.segments.shortTurns, droppedTurns: snapshot.segments.droppedTurns,
                         droppedSegments: snapshot.segments.droppedSegments)
    }

    /// The report as a `JSONSerialization` object graph, the control reply's form.
    public func foundationObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }

    private enum CodingKeys: String, CodingKey {
        case census = "main_job_census", mainJobs = "main_jobs", mainTurns = "main_turns"
    }

    // MARK: Rules

    /// The enqueuer of a job of `kind` from its stack, innermost first, by CmuxNextWakeups' `HopFrameResolver` rule: a
    /// main-actor job's stack starts at its first libswift_Concurrency frame (the hook's caller; the ring's own frames
    /// come before it), a post's at its first frame; the enqueuer is the first frame after that start which is not
    /// the runtime's, the system's or the census's own. ``unknownCaller`` when no frame is left (a cut stack, or a
    /// thread start with nothing of the app on it), never a runtime frame.
    static func caller(_ frames: [Frame], kind: MainJobRing.Kind) -> String {
        var from = frames.startIndex
        if kind == .mainActor {
            guard let entry = frames.firstIndex(where: { $0.image == MainJobRing.concurrencyRuntimeImage }) else { return unknownCaller }
            from = entry
        }
        guard let found = frames[from...].first(where: isEnqueuer) else { return unknownCaller }
        return found.symbol ?? "\(found.image ?? "?")+0x\(String(found.imageOffset ?? 0, radix: 16))"
    }

    /// Whether `frame` can name an enqueuer: not in a runtime or system image, not a `Task` or `MainActor` member,
    /// not the census's own code. An unresolved frame can.
    static func isEnqueuer(_ frame: Frame) -> Bool {
        if let image = frame.image, MainJobRing.enqueueRuntimeImages.contains(image) || systemImages.contains(image) { return false }
        guard let symbol = frame.symbol else { return true }
        if MainJobRing.enqueueRuntimeSymbolPrefixes.contains(where: { symbol.hasPrefix($0) || symbol.hasPrefix("_" + $0) }) { return false }
        var entity = Substring(symbol)
        for prefix in ["static ", "(extension in Swift):"] where entity.hasPrefix(prefix) { entity = entity.dropFirst(prefix.count) }
        if runtimeSymbolNames.contains(where: { entity.hasPrefix($0) }) { return false }
        return !censusSymbols.contains { symbol.contains($0) }
    }

    /// The `kind` field of a job of `kind`.
    static func kindName(_ kind: MainJobRing.Kind) -> String {
        switch kind {
        case .mainActor: "main_actor"
        case .mainDelivery: "main_delivery"
        case .runLoopBlock: "run_loop_block"
        case .timer: "timer"
        }
    }

    /// What took most of `turn`: its main jobs (named by the longest one's caller) or a phase.
    static func site(of turn: MainTurnSegments.Turn, longestCaller: String?) -> String {
        var site = longestCaller ?? "main_jobs"
        var most = turn.jobs.nanos
        for phase in MainTurnSegments.Phase.allCases where turn.nanos(phase) > most {
            most = turn.nanos(phase)
            site = phase.rawValue
        }
        return site
    }

    /// The main task with the most time in `turn` when it covered half of the turn or more, else nil.
    static func coveringTask(_ tasks: [MainJobCensus.TaskSpan], _ turn: MainTurnSegments.Turn) -> String? {
        var best: (name: String, nanos: UInt64)?
        var total: UInt64 = 0
        for task in tasks {
            let nanos = overlap([task], turn.startNanos, turn.durationNanos)
            total &+= nanos
            if nanos > 0, nanos > (best?.nanos ?? 0) { best = (task.name, nanos) }
        }
        guard let best, total * 2 >= turn.durationNanos else { return nil }
        return best.name
    }

    /// The time `tasks` (sorted by start) ran inside `[start, start + nanos)`.
    static func overlap(_ tasks: [MainJobCensus.TaskSpan], _ start: UInt64, _ nanos: UInt64) -> UInt64 {
        let end = start &+ nanos
        var total: UInt64 = 0
        for task in tasks {
            if task.startNanos >= end { break }
            let taskEnd = task.startNanos &+ task.durationNanos
            let from = max(start, task.startNanos), to = min(end, taskEnd)
            if to > from { total &+= to - from }
        }
        return total
    }

    /// One `[start, end)` stretch of `CLOCK_UPTIME_RAW` nanoseconds.
    typealias Interval = (start: UInt64, end: UInt64)

    /// `intervals` as disjoint stretches sorted by start: overlapping and nested ones joined.
    static func merged(_ intervals: [Interval]) -> [Interval] {
        var joined: [Interval] = []
        joined.reserveCapacity(intervals.count)
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.end > interval.start {
            if let last = joined.last, interval.start <= last.end {
                joined[joined.count - 1].end = max(last.end, interval.end)
            } else {
                joined.append(interval)
            }
        }
        return joined
    }

    /// The time inside `[start, end)` that `disjoint` (``merged(_:)``'s result) covers.
    static func covered(_ disjoint: [Interval], _ start: UInt64, _ end: UInt64) -> UInt64 {
        // The first stretch that ends after `start`: disjoint stretches sorted by start are sorted by end too.
        var low = 0, high = disjoint.count
        while low < high {
            let middle = (low + high) / 2
            if disjoint[middle].end <= start { low = middle + 1 } else { high = middle }
        }
        var total: UInt64 = 0
        for interval in disjoint[low...] {
            if interval.start >= end { break }
            total &+= min(end, interval.end) - max(start, interval.start)
        }
        return total
    }

    /// The QoS class name of a `qos_class_t` raw value.
    static func priorityName(_ raw: UInt8) -> String {
        switch raw {
        case 0x21: "userInteractive"
        case 0x19: "userInitiated"
        case 0x15: "default"
        case 0x11: "utility"
        case 0x09: "background"
        case 0: "unspecified"
        default: "qos_\(raw)"
        }
    }
}
#endif
