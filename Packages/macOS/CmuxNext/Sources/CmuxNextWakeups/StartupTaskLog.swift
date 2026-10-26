import CmuxNextCompat
import CmuxNextSignposts
import os

/// What ``StartupScheduler`` ran at launch: one record per task posted before completion (for
/// `debug.startup` and the StartupTrace ring), a launch signpost interval per task, and the main
/// task running now, which the hang watchdog reads from its own thread.
///
/// Chrome records the same per task (`Startup.AfterStartupTaskCount`,
/// `Startup.AfterStartupTaskDelayedUntilTime`, chrome/browser/after_startup_task_utils.cc) and tags
/// a hang with the running task (`base/task/common/task_annotator.h`). The watchdog's read costs the
/// main thread one atomic store per task: the name's address and length in one word, no lock.
///
/// ```swift
/// let log = StartupTaskLog(signposts: true)
/// if let task = log.currentMainTask { report.startupTask = task }   // the watchdog's thread
/// ```
public final class StartupTaskLog: Sendable {
    /// One task posted before startup completed.
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
        /// False once startup completed: later posts are not recorded.
        var open = true
    }

    // concurrency-allow: the records, appended on main and updated by lane threads at a task's start and end (lock carve-out: a short append or field write, no I/O under it).
    private let state = Mutex(State())
    /// The running main task's name: its address in the low 48 bits, its length in the high 16; 0 between tasks.
    private let current = Atomic<UInt64>(0)
    private let phaseValue = Atomic<Int>(Phase.beforeFirstFrame.rawValue)
    private let uptimeNanos: @Sendable () -> UInt64
    private let signposter: OSSignposter?

    /// - Parameters:
    ///   - signposts: Whether each task is a `startup.task` interval in the `launch` category (the app: true).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds); tests inject one they move.
    public init(signposts: Bool = false, uptimeNanos: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        self.uptimeNanos = uptimeNanos
        signposter = signposts ? OSSignposter(subsystem: SignpostCategory.subsystem, category: SignpostCategory.launch.rawValue) : nil
    }

    /// The records so far, in post order.
    public var records: [Record] { state.withLock { $0.records } }

    /// The records of posts that broke a rule.
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

    /// Records a post; returns its record index, or nil once startup completed.
    func posted(_ name: StaticString, _ priority: StartupPriority, _ destination: StartupDestination, violation: Violation?) -> Int? {
        let now = uptimeNanos()
        return state.withLock { state -> Int? in
            guard state.open else { return nil }
            state.records.append(Record(name: name, priority: priority, destination: destination, postedNanos: now, violation: violation))
            return state.records.count - 1
        }
    }

    /// Stops recording new posts (startup completed; the held tasks keep their records).
    func close() {
        state.withLock { $0.open = false }
    }

    /// Runs one task: its signpost interval, its record's start and duration, and, on main, the
    /// watchdog's current-task word (a nested task restores the outer one when it returns).
    func run(_ record: Int?, _ name: StaticString, _ priority: StartupPriority, onMain: Bool, _ body: () -> Void) {
        let outer = onMain ? current.exchange(Self.pack(name), ordering: .acquiringAndReleasing) : 0
        let interval = signposter.map { signposter in
            signposter.beginInterval("startup.task", id: signposter.makeSignpostID(),
                                     "name=\(name.description, privacy: .public) priority=\(priority.description, privacy: .public)")
        }
        let start = uptimeNanos()
        body()
        let end = uptimeNanos()
        if let signposter, let interval { signposter.endInterval("startup.task", interval) }
        if onMain { current.store(outer, ordering: .releasing) }
        guard let record else { return }
        state.withLock { state in
            state.records[record].startNanos = start
            state.records[record].durationNanos = end &- start
        }
    }

    /// Marks the completion in the signpost stream (`startup.complete reason=<reason>`).
    func completed(_ reason: StartupInProgressRef.Reason) {
        signposter?.emitEvent("startup.complete", "reason=\(reason.rawValue, privacy: .public)")
    }

    /// `name`'s address and length in one word (0 for a name with no pointer form or longer than 64 KiB).
    private static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation, name.utf8CodeUnitCount <= 0xFFFF else { return 0 }
        let address = UInt64(UInt(bitPattern: name.utf8Start))
        guard address >> 48 == 0 else { return 0 }
        return UInt64(name.utf8CodeUnitCount) << 48 | address
    }
}
