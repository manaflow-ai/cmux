import CmuxNextCompat
import CmuxNextSignposts
public import CmuxNextTrace

/// Task tracing for posted work: a post writes a `task.post` flow-out named by its site, and the run writes the
/// matching flow-in inside its `task.run` slice, so a trace draws an arrow from each post to its run. Chrome's
/// `TaskAnnotator` (base/task/common/task_annotator.cc) does this for every `PostTask`: `WillQueueTask` writes the
/// flow begin with `FROM_HERE`, `RunTask` the flow end inside the `ThreadPool_RunTask` slice. A ``BackgroundWork``
/// lane item's slice is its lane's (``LaneScheduler``, p02-threads-124), which its ``LaneJob`` puts the flow-in in;
/// a main-thread item's slice is the ticket's own (``Ticket/run(priority:_:)``).
///
/// Off (the `task` category is a recording category, never the black box's), a post and a run cost one relaxed
/// load and a branch each. On, the post's site file is interned once per file and runtime
/// (``CmuxNextTrace/TraceRuntime/siteFile(_:)``): one dictionary lookup. A `TaskTrace` holds only its runtime, so
/// making one costs nothing (``TracedTask`` makes one per post).
///
/// Records (plans/cmux-next/trace.md "Limits and open span requests", `task.post` and `task.run`):
/// - `task.post` flow-out: `arg0` the post site (file id bits 0-15, line bits 16-47), `arg1` the flow id.
/// - `task.run` B: `arg0` the ``Lane`` in bits 8-15 and the priority in bits 0-7 (a ``WorkPriority``'s or, on
///   ``Lane/main``, a ``MainWorkClass``'s `rawValue`), `arg1` the queue wait in microseconds (on the main lane
///   ``unknownWait`` when the post was not traced).
/// - `task.run` flow-in, inside the B: `arg0` the post site, `arg1` the flow id.
/// - `task.run` E.
/// - A ``TracedTask``'s run can suspend and resume on other threads, so it is a `task.run` AB/AE instead, keyed by
///   its flow id (``Ticket/beginAsyncRun(priority:)``).
///
/// ```swift
/// let ticket = trace.post(fileID: fileID, line: line, lane: .files)
/// // on the lane thread:
/// ticket.run(priority: TaskTrace.code(workClass)) { body() }  // main lane; a lane job calls ticket.arrive()
/// ```
public struct TaskTrace: Sendable {
    /// Where a traced item runs: the `task.run` begin's lane code, a ``BlockingLane``'s `rawValue` or 3 for main.
    public enum Lane: UInt8, Sendable {
        /// ``BlockingLane/files``.
        case files = 0
        /// ``BlockingLane/system``.
        case system = 1
        /// ``BlockingLane/cpu``.
        case cpu = 2
        /// The main thread (a queued control request).
        case main = 3
        /// Swift's cooperative pool (a ``TracedTask``).
        case pool = 4

        /// The code of a ``BackgroundWork`` lane.
        public init(_ lane: BlockingLane) {
            switch lane {
            case .files: self = .files
            case .system: self = .system
            case .cpu: self = .cpu
            }
        }
    }

    /// The `task.run` queue wait of an item whose post was not traced (the recording started after it).
    public static let unknownWait = UInt64.max
    /// Set in every task flow id: a key flow's high half is a pid, which never has bit 31 set.
    static let flowTag: UInt64 = 1 << 63

    /// The runtime the records go to.
    public let runtime: TraceRuntime

    /// Task tracing into `runtime`.
    public init(runtime: TraceRuntime) {
        self.runtime = runtime
    }

    /// The `task` category's bit.
    static var categoryBit: UInt8 { SignpostCategory.task.traceBit }

    /// The priority code of a main-thread item of `workClass` (``MainWorkClass/rawValue``).
    public static func code(_ workClass: MainWorkClass) -> UInt8 {
        UInt8(truncatingIfNeeded: workClass.rawValue)
    }

    /// Marks a post at `fileID`:`line` of an item that runs on `lane`: writes the `task.post` flow-out when the
    /// `task` category is on, and returns the ticket the run hands to ``Ticket/run(priority:_:)``.
    public func post(fileID: StaticString, line: UInt, lane: Lane) -> Ticket {
        prepare(fileID: fileID, line: line, lane: lane).write()
    }

    /// The post at `fileID`:`line` of an item that runs on `lane`, its site interned and its record not written
    /// yet: a queue that can refuse the item resolves the site before it takes its lock and writes the post
    /// (``PendingPost/write()``, lock-free) only once it accepted the item, so a refused item leaves no post.
    public func prepare(fileID: StaticString, line: UInt, lane: Lane) -> PendingPost {
        let traced = runtime.isEnabled(categoryBit: Self.categoryBit)
        return PendingPost(trace: self, lane: lane, file: traced ? runtime.siteFile(fileID) : nil, line: line, traced: traced)
    }

    /// A post whose site is resolved and whose `task.post` record is not written yet (``prepare(fileID:line:lane:)``).
    public struct PendingPost: Sendable {
        let trace: TaskTrace
        let lane: Lane
        let file: TraceRuntime.InternedName?
        let line: UInt
        /// The `task` category was on when the site was resolved.
        let traced: Bool

        /// Writes the `task.post` flow-out when the category is on (no lock: one ring write) and returns the ticket
        /// the run hands to ``Ticket/run(priority:_:)``.
        public func write() -> Ticket {
            let untraced = Ticket(trace: trace, lane: lane, flow: 0, postNanos: 0, file: nil, line: line)
            guard traced else { return untraced }
            let runtime = trace.runtime
            let flow = TaskTrace.flowTag | runtime.nextAsyncScope()
            guard let posted = runtime.write(name: SignpostName.taskPost.rawValue, categoryBit: TaskTrace.categoryBit,
                                             phase: .flowOut, file: file, line: line, arg1: flow) else { return untraced }
            return Ticket(trace: trace, lane: lane, flow: flow, postNanos: posted, file: file, line: line)
        }
    }

    /// What a post hands its run: the flow (0 when the post was not traced), the post time and the site.
    public struct Ticket: Sendable {
        let trace: TaskTrace
        let lane: Lane
        let flow: UInt64
        let postNanos: UInt64
        let file: TraceRuntime.InternedName?
        let line: UInt

        /// Runs `body` inside a `task.run` slice when the `task` category is on, with the flow-in of a traced post.
        /// The category is read once: a written begin always gets its end.
        ///
        /// - Parameters:
        ///   - priority: the priority code the item runs at (``TaskTrace/code(_:)``).
        ///   - body: the item.
        /// - Returns: What `body` returns.
        public func run<T>(priority: UInt8, _ body: () throws -> T) rethrows -> T {
            let runtime = trace.runtime
            guard runtime.isEnabled(categoryBit: TaskTrace.categoryBit) else { return try body() }
            let name = SignpostName.taskRun.rawValue, bit = TaskTrace.categoryBit
            let now = runtime.nowNanos()
            let wait = flow == 0 ? TaskTrace.unknownWait : (now > postNanos ? now - postNanos : 0) / 1_000
            let began = runtime.write(name: name, categoryBit: bit, phase: .begin,
                                      arg0: UInt64(lane.rawValue) << 8 | UInt64(priority), arg1: wait)
            if began { arrive() }
            defer { if began { runtime.writeEnd(name: name, categoryBit: bit, phase: .end) } }
            return try body()
        }

        /// Writes the flow-in of a traced post while the `task` category is on; call it right after the run's
        /// `task.run` begin, so the flow ends in that slice.
        public func arrive() {
            guard flow != 0 else { return }
            trace.runtime.write(name: SignpostName.taskRun.rawValue, categoryBit: TaskTrace.categoryBit,
                                phase: .flowIn, file: file, line: line, arg1: flow)
        }

        /// Whether the post wrote its `task.post` flow-out.
        public var isTraced: Bool { flow != 0 }

        /// Opens the `task.run` async slice (AB) of a run that can suspend and resume on other threads (a
        /// ``TracedTask``'s) when the `task` category is on, and writes the post's flow-in right after it on the
        /// starting thread. Its id is the post's flow id, or a new one when the post was not traced. AB arg0: the
        /// priority in bits 0-7, the lane in bits 8-15 and the queue wait in us in bits 16-63
        /// (``TaskTrace/unknownAsyncWait`` when the post was not traced); AB arg1: the id.
        ///
        /// - Parameter priority: the priority code the run starts at (a ``WorkPriority``'s `rawValue`).
        /// - Returns: The slice; call ``AsyncRun/end()`` when the run returns, on whatever thread it ends.
        public func beginAsyncRun(priority: UInt8) -> AsyncRun {
            let runtime = trace.runtime
            guard runtime.isEnabled(categoryBit: TaskTrace.categoryBit) else { return AsyncRun(runtime: nil, id: 0) }
            let id = isTraced ? flow : TaskTrace.flowTag | runtime.nextAsyncScope()
            let now = runtime.nowNanos()
            let waited = (now > postNanos ? now - postNanos : 0) / 1_000
            let wait = isTraced ? min(waited, TaskTrace.unknownAsyncWait - 1) : TaskTrace.unknownAsyncWait
            let arg0 = wait << 16 | UInt64(lane.rawValue) << 8 | UInt64(priority)
            guard runtime.write(name: SignpostName.taskRun.rawValue, categoryBit: TaskTrace.categoryBit,
                                phase: .asyncBegin, flags: .asyncID, arg0: arg0, arg1: id) else {
                return AsyncRun(runtime: nil, id: 0)
            }
            arrive()
            return AsyncRun(runtime: runtime, id: id)
        }
    }

    /// The `task.run` AB arg0 queue wait (bits 16-63) of a run whose post was not traced.
    public static let unknownAsyncWait: UInt64 = (1 << 48) - 1

    /// An open `task.run` async slice (``Ticket/beginAsyncRun(priority:)``).
    public struct AsyncRun: Sendable {
        /// The runtime the AB went to; nil when none was written.
        let runtime: TraceRuntime?
        /// The slice's async id.
        let id: UInt64

        /// Writes the slice's AE, on any thread, when its AB was written (also after the category turned off).
        public func end() {
            runtime?.writeEnd(name: SignpostName.taskRun.rawValue, categoryBit: TaskTrace.categoryBit,
                              phase: .asyncEnd, flags: .asyncID, arg1: id)
        }
    }
}

extension BackgroundWork {
    /// Traces the post of an item at `site` that runs on `lane`, on the posting thread.
    func tracePost(_ site: CallSite, on lane: BlockingLane) -> TaskTrace.Ticket {
        taskTrace.post(fileID: site.fileID, line: site.line, lane: TaskTrace.Lane(lane))
    }
}

extension MainTaskOwner {
    /// The owner's index on its board: the number trace records name it by.
    public var traceID: UInt32 { index }
}
