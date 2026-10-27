import CmuxNextCompat
public import CmuxNextSignposts
import class CmuxSafeConcurrency.Invariant

/// What ``StartupScheduler`` ran at launch: one record per task posted before completion, and per
/// post that broke a rule at any time (for `debug.startup` and the StartupTrace ring), a
/// `launch.startup_task` signpost interval per task (also a Release trace ring slice), and the main
/// task running now, which the hang watchdog reads from its own thread.
///
/// Chrome records the same per task (`Startup.AfterStartupTaskCount`,
/// `Startup.AfterStartupTaskDelayedUntilTime`, chrome/browser/after_startup_task_utils.cc) and tags
/// a hang with the running task (`base/task/common/task_annotator.h`). The watchdog's read costs the
/// main thread one atomic store per task: the name's address and length in one word, no lock.
///
/// ```swift
/// let log = StartupTaskLog(signposter: .launch)
/// if let task = log.currentMainTask { report.startupTask = task }   // the watchdog's thread
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

    // concurrency-allow: the records, appended on main and updated by lane threads at a task's start and end (lock carve-out: a short append or field write, no I/O under it).
    private let state = Mutex(State())
    /// The running main task's name: its address in the low 48 bits, its length in the high 16; 0 between tasks.
    private let current = Atomic<UInt64>(0)
    private let phaseValue = Atomic<Int>(Phase.beforeFirstFrame.rawValue)
    private let uptimeNanos: @Sendable () -> UInt64
    private let signposter: Signposter?

    /// - Parameters:
    ///   - signposter: Where each task's `launch.startup_task` interval and the `launch.startup_complete`
    ///     event go (the app: ``Signposter/launch``; tests: nil, or one on their own `TraceRuntime`).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds); tests inject one they move.
    public init(signposter: Signposter? = nil, uptimeNanos: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        Invariant.debugCheck(signposter.map { $0.category == .launch } ?? true, "startup-signposts-launch-category",
                             "startup signposts are in the launch category")
        self.uptimeNanos = uptimeNanos
        self.signposter = signposter
    }

    /// The app's log: tasks and the completion on ``Signposter/launch`` (os_signpost and the process's trace ring).
    public static func signposted() -> StartupTaskLog { StartupTaskLog(signposter: .launch) }

    /// The records so far, in post order.
    public var records: [Record] { state.withLock { $0.records } }

    /// The records of posts that broke a rule, before or after completion.
    public var violations: [Record] { records.filter { $0.violation != nil } }

    /// The main task running now (any thread), or nil between tasks.
    public var currentMainTask: String? {
        let packed = current.load(ordering: .acquiring)
        guard packed != 0, let start = UnsafePointer<UInt8>(bitPattern: UInt(packed & 0x0000_FFFF_FFFF_FFFF)) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: start, count: Int(packed >> 48)), as: UTF8.self)
    }

    /// The scheduler's phase now (any thread).
    public var phase: Phase { Phase(rawValue: phaseValue.load(ordering: .acquiring)) ?? .beforeFirstFrame }

    func setPhase(_ phase: Phase) {
        phaseValue.store(phase.rawValue, ordering: .releasing)
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
        let outer = onMain ? current.exchange(Self.pack(name), ordering: .acquiringAndReleasing) : 0
        let interval = signposter.map { signposter in
            signposter.begin(.launchStartupTask, "name=\(name) priority=\(priority)", arg0: UInt64(priority.rawValue) + 1)
        }
        let start = uptimeNanos()
        body()
        let end = uptimeNanos()
        if let signposter, let interval { signposter.end(.launchStartupTask, interval) }
        if onMain { current.store(outer, ordering: .releasing) }
        guard let record else { return }
        state.withLock { state in
            state.records[record].startNanos = start
            state.records[record].durationNanos = end &- start
        }
    }

    /// Marks the completion in the signpost stream and the ring (`launch.startup_complete reason=<reason>`;
    /// arg0 the reason's position + 1, arg1 the afterStartup tasks held until then).
    func completed(_ reason: StartupInProgressRef.Reason, heldTasks: Int) {
        guard let signposter else { return }
        let position = StartupInProgressRef.Reason.allCases.firstIndex(of: reason).map { UInt64($0) + 1 } ?? 0
        signposter.event(.launchStartupComplete, "reason=\(reason)", arg0: position, arg1: UInt64(heldTasks))
    }

    /// `name`'s address and length in one word (0 for a name with no pointer form or longer than 64 KiB).
    private static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation, name.utf8CodeUnitCount <= 0xFFFF else { return 0 }
        let address = UInt64(UInt(bitPattern: name.utf8Start))
        guard address >> 48 == 0 else { return 0 }
        return UInt64(name.utf8CodeUnitCount) << 48 | address
    }
}
