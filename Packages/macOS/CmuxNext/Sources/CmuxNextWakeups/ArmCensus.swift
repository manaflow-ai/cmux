#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Foundation

/// The launch's arm census (plans/cmux-next/chrome-parity/p08-startup.md, task 085, queue Q13): each timer, deadline,
/// watcher and system observer armed before startup completed, with its owner, the site that made it and its first
/// fire, so `startup-queue.py arms` names the launch arms that template 086 moves to an afterStartup post.
///
/// One record per armed object: a ``DemandTimer``, a ``MainDeadline``, a one-shot ``AlignedWakeups`` deadline, a
/// ``FolderChanges`` stream, an ``AppEvents`` channel on a system center, and each watch whose owner keeps an
/// ``ArmCensusWatch`` (ConfigFileWatcher, FolderWatcher, FileTreeWatcher, ControlSocketPathWatch, RetryWake and the
/// crash forwarders). Its first arm while the census records, how many times it was armed until its first fire or ``close()``, and its first fire,
/// written whenever that comes (the bench reads launch to +10 s). An object records once: after its first fire it
/// never records again. Chrome keeps the same facts per delayed task, the `posted_from` location and the queue time
/// (base/pending_task.h, read by base/task/common/task_annotator.cc), and a timer's first run is its task's run.
///
/// Debug and bench-hooks builds only, and recording only between ``start(processStartNanos:)`` (the app calls it in
/// `main` when ``environmentKey`` is `1`) and ``close()`` (startup complete). Otherwise an arm costs one atomic load.
/// The census belongs to its ``WakeupLedger`` (``WakeupLedger/armCensus``), the sink every timer and watch is already
/// given, and reads the ledger's clock. Records are bounded by ``capacity``; past it an arm is counted in
/// ``Snapshot/dropped``.
///
/// ```swift
/// ledger.armCensus.start(environment: ProcessInfo.processInfo.environment, processStartNanos: start)
/// ledger.armCensus.close(after: order.startup)
/// let reply = ledger.armCensus.snapshot().foundationObject   // debug.startup.arms
/// ```
public final class ArmCensus: Sendable {
    /// `CMUX_NEXT_ARM_CENSUS=1` arms the census for one launch.
    public static let environmentKey = "CMUX_NEXT_ARM_CENSUS"
    /// The records kept (a launch arms a few hundred).
    public static let capacity = 4_096

    /// What was armed.
    public typealias Kind = ArmCensusKind

    /// The source line that made the armed object.
    public struct Site: Sendable, CustomStringConvertible {
        /// The source file, its `#fileID`.
        public let file: StaticString
        /// The source line.
        public let line: UInt

        /// A site from its `#fileID` and line.
        public init(file: StaticString, line: UInt) {
            self.file = file
            self.line = line
        }

        public var description: String { "\(file):\(line)" }
    }

    /// One armed object.
    public struct Arm: Sendable {
        /// What it is (a timer, a deadline, a watcher, a system observer).
        public let kind: Kind
        /// Who armed it.
        public let owner: String
        /// The line that made it.
        public let site: Site
        /// `CLOCK_UPTIME_RAW` nanoseconds at its first arm.
        public let armedNanos: UInt64
        /// Times it was armed before its first fire while the census recorded, the first included.
        public internal(set) var count: Int
        /// `CLOCK_UPTIME_RAW` nanoseconds at its first fire; nil while it has not fired.
        public internal(set) var firstFireNanos: UInt64?
    }

    /// A record claimed by ``armed(_:owner:site:)``: the owner keeps it until its first fire.
    public struct Slot: Sendable, Equatable {
        let index: Int
    }

    /// What the census holds now.
    public struct Snapshot: Sendable {
        /// True once ``ArmCensus/start(processStartNanos:)`` ran.
        public let started: Bool
        /// True once ``ArmCensus/close()`` ran: no new arm is recorded, fires still are.
        public let closed: Bool
        /// Arms past ``ArmCensus/capacity``.
        public let dropped: Int
        /// The zero of the report's times (`CLOCK_UPTIME_RAW` nanoseconds).
        public let processStartNanos: UInt64
        /// In first-arm order.
        public let arms: [Arm]

        /// `debug.startup.arms`' payload: `arm_census` (`armed`, `closed`, `dropped`, `capacity`) and `arms`, one
        /// entry per record (`kind`, `owner`, `site`, `armed_ms`, `count`, `first_fire_ms` or null). Times are
        /// milliseconds since process start.
        public var foundationObject: [String: Any] {
            func ms(_ nanos: UInt64) -> Double { (Double(Int64(bitPattern: nanos &- processStartNanos)) / 1e5).rounded() / 10 }
            let records = arms.map { arm -> [String: Any] in
                let fire: Any
                if let nanos = arm.firstFireNanos { fire = ms(nanos) } else { fire = NSNull() }
                return ["kind": arm.kind.rawValue, "owner": arm.owner, "site": arm.site.description,
                        "armed_ms": ms(arm.armedNanos), "count": arm.count, "first_fire_ms": fire]
            }
            let census: [String: Any] = ["armed": started, "closed": closed, "dropped": dropped, "capacity": ArmCensus.capacity]
            return ["arm_census": census, "arms": records]
        }
    }

    private struct State {
        var started = false
        var closed = false
        var processStartNanos: UInt64 = 0
        var dropped = 0
        var arms: [Arm] = []
    }

    // concurrency-allow: bench and Debug only, recording only in an armed launch; each critical section is one append or one field write, with no call out and no I/O, so it is a leaf lock under a timer's own.
    private let state = Mutex(State())
    /// True between start and close: the one load an arm pays when the census does not record.
    private let recording = Atomic<Bool>(false)
    private let uptimeNanos: @Sendable () -> UInt64

    /// - Parameter uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds); its ledger's.
    public init(uptimeNanos: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        self.uptimeNanos = uptimeNanos
    }

    /// True while arms are recorded.
    public var isRecording: Bool { recording.load(ordering: .relaxed) }

    /// Starts recording; times are reported from `processStartNanos`. A second start does nothing.
    public func start(processStartNanos: UInt64) {
        let started = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            state.processStartNanos = processStartNanos
            state.arms.reserveCapacity(Self.capacity)
            return true
        }
        if started { recording.store(true, ordering: .releasing) }
    }

    /// ``start(processStartNanos:)`` when `environment` sets ``environmentKey`` to `1`; returns whether it did.
    @discardableResult
    public func start(environment: [String: String], processStartNanos: UInt64) -> Bool {
        guard environment[Self.environmentKey] == "1" else { return false }
        start(processStartNanos: processStartNanos)
        return true
    }

    /// Stops recording arms; the records keep taking their first fires.
    public func close() {
        recording.store(false, ordering: .releasing)
        state.withLock { $0.closed = $0.started }
    }

    /// Closes the census when `startup` completes.
    @MainActor
    public func close(after startup: StartupScheduler) {
        startup.whenComplete { [self] _ in close() }
    }

    /// Records the first arm of an object; nil when the census does not record or is full.
    func armed(_ kind: Kind, owner: String, site: Site) -> Slot? {
        guard isRecording else { return nil }
        let now = uptimeNanos()
        return state.withLock { state -> Slot? in
            guard !state.closed else { return nil }
            guard state.arms.count < Self.capacity else {
                state.dropped += 1
                return nil
            }
            state.arms.append(Arm(kind: kind, owner: owner, site: site, armedNanos: now, count: 1, firstFireNanos: nil))
            return Slot(index: state.arms.count - 1)
        }
    }

    /// Counts another arm of a recorded object while the census records.
    func rearmed(_ slot: Slot) {
        guard isRecording else { return }
        state.withLock { state in
            guard !state.closed else { return }
            state.arms[slot.index].count += 1
        }
    }

    /// Records a recorded object's first fire (any time, also after close).
    func fired(_ slot: Slot) {
        let now = uptimeNanos()
        state.withLock { state in
            if state.arms[slot.index].firstFireNanos == nil { state.arms[slot.index].firstFireNanos = now }
        }
    }

    /// The records so far.
    public func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(started: state.started, closed: state.closed, dropped: state.dropped,
                     processStartNanos: state.processStartNanos, arms: state.arms)
        }
    }
}

/// What an armed object keeps for the census: its record, until the first fire ends it.
struct ArmCensusEntry: Sendable {
    private var slot: ArmCensus.Slot?
    private var done = false

    /// One arm: the first records the object, a later one before its first fire is counted.
    mutating func armed(in census: ArmCensus, _ kind: ArmCensus.Kind, owner: String, site: ArmCensus.Site) {
        guard !done else { return }
        if let slot {
            census.rearmed(slot)
        } else if census.isRecording {
            slot = census.armed(kind, owner: owner, site: site)
        }
    }

    /// The object fired: its first fire is recorded, and it records nothing more.
    mutating func fired(in census: ArmCensus) {
        guard !done, let slot else { return }
        census.fired(slot)
        self.slot = nil
        done = true
    }
}
#endif
