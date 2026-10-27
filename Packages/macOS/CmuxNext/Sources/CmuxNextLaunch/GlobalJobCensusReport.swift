#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextWakeups
import Foundation

/// `debug.startup.global_jobs`' payload, built from a ``GlobalJobCensus/Snapshot`` off the main thread: the tasks
/// `startup-queue.py globaljobs` ranks (queue Q12, task template 083). Times are milliseconds since process start.
///
/// - `global_jobs`: one record per task that started on the cooperative pool. `caller` is the creator: from the first
///   frame of libswift_Concurrency (the hook's caller; the census's own frames come before it), the first frame
///   outside the runtime's and the system's images. `via` is `background_work_task` when that frame is
///   ``BackgroundWork/ownTaskFrames``: a `BackgroundWork.task` starts at once, outside the launch fence, so it stays a
///   Q12 task, and `caller` names the frame past it. A census task has no `lane`: lane items do not reach the pool.
///   `priority` is the raw `TaskPriority` (0: none stated), `origin` `main` or `off_main`, and `run_ms` is null: the
///   hook sees an enqueue, not the run.
/// - `global_job_census`: whether the hook ran, and what it counted and did not keep.
///
/// ```swift
/// let report = GlobalJobCensusReport(census.snapshot()) { addresses in symbolicator.frames(for: addresses).map(frame) }
/// let reply = try report.foundationObject()
/// ```
public nonisolated struct GlobalJobCensusReport: Sendable, Encodable {
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
        /// ``GlobalJobCensusReport/backgroundWorkTask`` for a task that `BackgroundWork.task` started; nil for any other.
        public var via: String?
        /// The raw `TaskPriority`: 0 none stated, 9 background, 17 utility, 21 medium, 25 user-initiated.
        public var priority: Int
        /// `main` or `off_main`: the thread that enqueued it.
        public var origin: String
        public var enqueuedMs: Double

        private enum CodingKeys: String, CodingKey {
            case caller, via, priority, origin
            case enqueuedMs = "enqueued_ms", runMs = "run_ms"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(caller, forKey: .caller)
            try container.encode(via, forKey: .via)
            try container.encode(priority, forKey: .priority)
            try container.encode(origin, forKey: .origin)
            try container.encode(enqueuedMs, forKey: .enqueuedMs)
            try container.encodeNil(forKey: .runMs)
        }
    }

    public struct Summary: Sendable, Equatable, Encodable {
        public var armed = true
        /// ``GlobalJobCensus/HookState``'s name: `installed`, `missing`, `busy` or `not_installed`.
        public var hook: String
        public var frozen: Bool
        public var tasks: Int
        public var pendingTasks: Int
        public var droppedTasks: Int
        public var resumptions: Int
        public var actorJobs: Int
        public var untrackedTasks: Int

        private enum CodingKeys: String, CodingKey {
            case armed, hook, frozen, tasks, resumptions
            case pendingTasks = "pending_tasks", droppedTasks = "dropped_tasks", actorJobs = "actor_jobs"
            case untrackedTasks = "untracked_tasks"
        }
    }

    /// ``JobRecord/via`` for a task that `BackgroundWork.task` started.
    public static let backgroundWorkTask = "background_work_task"
    /// The image of the hook's caller: the frames before its first one are the census's own.
    static let entryImage = "libswift_Concurrency.dylib"
    /// What the creator search skips after the entry: the runtime's and the system's images a task's start or first
    /// hop passes through (an async stack's frames come after the run loop's or the pool thread's own).
    static let systemImages: Set<String> = [entryImage, "libswiftCore.dylib", "libdispatch.dylib", "libswiftDispatch.dylib",
                                            "libsystem_pthread.dylib", "libsystem_kernel.dylib", "libsystem_platform.dylib",
                                            "libsystem_c.dylib", "libobjc.A.dylib", "CoreFoundation", "Foundation", "AppKit",
                                            "HIToolbox"]

    public var census: Summary
    public var globalJobs: [JobRecord]

    /// - Parameters:
    ///   - snapshot: What the census held.
    ///   - symbolize: Resolves one task's return addresses, innermost first (the app: `StackSymbolicator`); called once
    ///     per distinct stack.
    public init(_ snapshot: GlobalJobCensus.Snapshot, symbolize: ([UInt]) -> [Frame]) {
        let start = snapshot.processStartNanos
        var creators: [[UInt]: (caller: String, via: String?)] = [:]
        globalJobs = snapshot.jobs.map { job in
            let creator = creators[job.frames] ?? Self.creator(symbolize(job.frames))
            creators[job.frames] = creator
            let since = job.enqueuedNanos > start ? job.enqueuedNanos - start : 0
            return JobRecord(caller: creator.caller, via: creator.via, priority: Int(job.priority),
                             origin: job.onMain ? "main" : "off_main", enqueuedMs: (Double(since) / 1_000).rounded() / 1_000)
        }
        let counts = snapshot.counts
        census = Summary(hook: snapshot.hook.name, frozen: snapshot.frozen, tasks: snapshot.jobs.count,
                         pendingTasks: counts.pending, droppedTasks: counts.dropped, resumptions: counts.resumptions,
                         actorJobs: counts.actorJobs, untrackedTasks: counts.untracked)
    }

    /// The report as a `JSONSerialization` object graph, the control reply's form.
    public func foundationObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }

    private enum CodingKeys: String, CodingKey {
        case census = "global_job_census", globalJobs = "global_jobs"
    }

    // MARK: Rules

    /// The creator of a task from its stack (innermost first): from the first ``entryImage`` frame, the first frame
    /// outside ``systemImages`` and not ``isEmittedRuntime(_:)``; when that is a ``BackgroundWork/ownTaskFrames`` frame,
    /// `via` is ``backgroundWorkTask`` and the creator is the next such frame past it. `?` when the stack has no entry frame or none past the system frames.
    static func creator(_ frames: [Frame]) -> (caller: String, via: String?) {
        guard let entry = frames.firstIndex(where: { $0.image == entryImage }) else { return ("?", nil) }
        let own = frames[entry...].filter { frame in
            !(frame.image.map(systemImages.contains) ?? false) && !(frame.symbol.map(isEmittedRuntime) ?? false)
        }
        guard let first = own.first else { return ("?", nil) }
        guard isBackgroundWorkTask(first) else { return (name(first), nil) }
        let past = own.dropFirst().first { !isBackgroundWorkTask($0) }
        return (past.map(name) ?? name(first), backgroundWorkTask)
    }

    /// Whether `symbol` (demangled) is a standard-library function the compiler emitted into the caller's image
    /// (`Task.detached`, `Task.init`, `TaskGroup.addTask` are `@_alwaysEmitIntoClient`): not inlined in a Debug build,
    /// such a frame would name every task's creator `Swift.Task.detached`.
    static func isEmittedRuntime(_ symbol: String) -> Bool {
        var core = Substring(symbol)
        if core.hasPrefix("generic specialization <"), let of = core.range(of: "> of ") { core = core[of.upperBound...] }
        for prefix in ["merged ", "static "] where core.hasPrefix(prefix) { core = core.dropFirst(prefix.count) }
        return core.hasPrefix("Swift.") || core.hasPrefix("(extension in Swift):")
    }

    static func isBackgroundWorkTask(_ frame: Frame) -> Bool {
        guard let symbol = frame.symbol else { return false }
        return BackgroundWork.ownTaskFrames.contains { symbol.contains($0) }
    }

    static func name(_ frame: Frame) -> String {
        frame.symbol ?? "\(frame.image ?? "?")+0x\(String(frame.imageOffset ?? 0, radix: 16))"
    }
}
#endif
