import CmuxNextCompat
public import CmuxNextSignposts

/// What ``StartupScheduler`` ran at launch: one record per task posted before completion, and per
/// post that broke a rule at any time (for `debug.startup` and the StartupTrace ring), a
/// `launch.startup_task` signpost interval per task (also a Release trace ring slice), and the main
/// task running now, which the hang watchdog reads from its own thread.
///
/// Chrome records the same per task (`Startup.AfterStartupTaskCount`,
/// `Startup.AfterStartupTaskDelayedUntilTime`, chrome/browser/after_startup_task_utils.cc) and tags
/// a hang with the running task (`base/task/common/task_annotator.h`). The running task and the phase
/// live in the launch's ``StartupTaskTag``, which the watchdog reads from its own thread: one atomic
/// exchange at a task's start and one store at its end, the name's address and length in one word, no lock.
///
/// ```swift
/// let log = StartupTaskLog(signposter: .launch, tag: tag)   // `tag`: made first in main(), also the watchdog's
/// let reading = log.tag.read()                              // any thread
/// ```
public final class StartupTaskLog: Sendable {
    /// One task posted before startup completed, or a post that broke a rule (``violation``).
    public struct Record: Sendable {
        /// The task's name.
        public let name: StaticString
        /// The priority it was posted at.
        public let priority: StartupPriority
        /// Where it runs.
        public let destination: StartupDestination
        /// `CLOCK_UPTIME_RAW` nanoseconds at the post.
        public let postedNanos: UInt64
        /// When it started, nil until it does.
        public internal(set) var startNanos: UInt64?
        /// How long it ran, nil until it ends.
        public internal(set) var durationNanos: UInt64?
        /// What the post broke, if anything.
        public let violation: Violation?
    }

    /// A post that broke the startup rules (`debug.startup`'s `critical_violations`).
    public nonisolated enum Violation: String, Sendable, CaseIterable {
        /// A ``StartupPriority/critical`` post whose name is not in the critical allowlist.
        case notInCriticalAllowlist
        /// A ``StartupPriority/onDemand`` post (it runs as afterStartup).
        case onDemandPosted
    }

    /// The scheduler's phase as the watchdog sees it.
    public nonisolated enum Phase: Int, Sendable, CustomStringConvertible {
        /// Before the first frame was committed.
        case beforeFirstFrame
        /// After the first frame, before completion.
        case afterFirstFrame
        /// Startup completed.
        case complete
        /// Quit began.
        case quitting

        public var description: String {
            switch self {
            case .beforeFirstFrame: "beforeFirstFrame"
            case .afterFirstFrame: "afterFirstFrame"
            case .complete: "complete"
            case .quitting: "quitting"
            }
        }
    }

    private struct State {
        var records: [Record] = []
        /// False once startup completed: later posts are recorded only when they break a rule.
        var open = true
    }

    /// The running main task and the phase, shared with the main-thread watchdog.
    public let tag: StartupTaskTag
    // concurrency-allow: the records, appended on main and updated by lane threads at a task's start and end (lock carve-out: a short append or field write, no I/O under it).
    private let state = Mutex(State())
    private let uptimeNanos: @Sendable () -> UInt64
    private let signposter: Signposter?

    /// - Parameters:
    ///   - signposter: Where each task's `launch.startup_task` interval and the `launch.startup_complete`
    ///     event go (the app: ``Signposter/launch``; tests: nil, or one on their own `TraceRuntime`).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds); tests inject one they move.
    ///   - tag: Where the running main task and the phase are kept for the watchdog (the app: the one `main()` made first).
    public init(signposter: Signposter? = nil, uptimeNanos: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime,
                tag: StartupTaskTag = StartupTaskTag()) {
        assert(signposter.map { $0.category == .launch } ?? true, "startup signposts are in the launch category")
        self.tag = tag
        self.uptimeNanos = uptimeNanos
        self.signposter = signposter
    }

    /// The app's log: tasks and the completion on ``Signposter/launch`` (os_signpost and the process's trace ring),
    /// the running task and phase on `tag`.
    public static func signposted(tag: StartupTaskTag = StartupTaskTag()) -> StartupTaskLog {
        StartupTaskLog(signposter: .launch, tag: tag)
    }

    /// The records so far, in post order.
    public var records: [Record] { state.withLock { $0.records } }

    /// The records of posts that broke a rule, before or after completion.
    public var violations: [Record] { records.filter { $0.violation != nil } }

    /// The main task running now (any thread), or nil between tasks.
    public var currentMainTask: String? { tag.currentTask }

    /// The scheduler's phase now (any thread).
    public var phase: Phase { tag.phase }

    func setPhase(_ phase: Phase) {
        tag.setPhase(phase)
    }

    /// Records a post; returns its record index, or nil for a post after completion that broke no rule.
    func posted(_ name: StaticString, _ priority: StartupPriority, _ destination: StartupDestination, violation: Violation?) -> Int? {
        let now = uptimeNanos()
        return state.withLock { state -> Int? in
            guard state.open || violation != nil else { return nil }
            state.records.append(Record(name: name, priority: priority, destination: destination, postedNanos: now, violation: violation))
            return state.records.count - 1
        }
    }

    /// Stops recording new posts that break no rule (startup completed; the held tasks keep their records).
    func close() {
        state.withLock { $0.open = false }
    }

    /// Runs one task: its signpost interval, its record's start and duration, and, on main, the
    /// watchdog's current-task word (a nested task restores the outer one when it returns).
    func run(_ record: Int?, _ name: StaticString, _ priority: StartupPriority, onMain: Bool, _ body: () -> Void) {
        let outer = onMain ? tag.enter(name) : 0
        let interval = signposter.map { signposter in
            signposter.begin(.launchStartupTask, "name=\(name) priority=\(priority)", arg0: UInt64(priority.rawValue) + 1)
        }
        let start = uptimeNanos()
        body()
        let end = uptimeNanos()
        if let signposter, let interval { signposter.end(.launchStartupTask, interval) }
        if onMain { tag.leave(restoring: outer) }
        guard let record else { return }
        state.withLock { state in
            state.records[record].startNanos = start
            state.records[record].durationNanos = end &- start
        }
    }

    /// Runs a launch start the launch turn calls directly (`LaunchStart.runNow`, no post and no record):
    /// its `launch.startup_task` interval with `priority=launchTurn` and arg0 0, and the watchdog's
    /// current-task word while it runs.
    ///
    /// - Parameters:
    ///   - name: The start's name (`Domain.step`).
    ///   - body: The start.
    /// - Returns: What the start returns.
    @MainActor @discardableResult
    public func runInLaunchTurn<T>(_ name: StaticString, _ body: () -> T) -> T {
        let outer = tag.enter(name)
        let interval = signposter.map { signposter in
            signposter.begin(.launchStartupTask, "name=\(name) priority=launchTurn", arg0: 0)
        }
        defer {
            if let signposter, let interval { signposter.end(.launchStartupTask, interval) }
            tag.leave(restoring: outer)
        }
        return body()
    }

    /// Marks the completion in the signpost stream and the ring (`launch.startup_complete reason=<reason>`;
    /// arg0 the reason's position + 1, arg1 the afterStartup tasks held until then).
    func completed(_ reason: StartupInProgressRef.Reason, heldTasks: Int) {
        guard let signposter else { return }
        let position = StartupInProgressRef.Reason.allCases.firstIndex(of: reason).map { UInt64($0) + 1 } ?? 0
        signposter.event(.launchStartupComplete, "reason=\(reason)", arg0: position, arg1: UInt64(heldTasks))
    }
}
