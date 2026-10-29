#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
public import CmuxNextWakeups
import CoreFoundation

/// The launch's main-job census (plans/cmux-next/chrome-parity/p08-startup.md, task 080, queue Q11): who put work on
/// the main thread before startup completed, and which main turns ran outside a StartupScheduler task.
///
/// Three sources, one clock (`CLOCK_UPTIME_RAW`):
/// - ``MainJobRing``: each main-actor job (`swift_task_enqueueMainExecutor_hook`) and each main-thread post the app
///   makes (a ``MainDelivery`` hop, a `MainRunLoopBlock`, a `DemandTimer` fire), with its enqueuer's return
///   addresses (a timer: its owner), priority and run time;
/// - two main run-loop observers (``MainTurnSegments``): each turn's time per phase, and each timer, main-queue or
///   source callout stretch the ring did not time (the system's own callouts);
/// - the StartupScheduler's main tasks, read when the census is reported (``snapshot(mainTasks:)``), which tag
///   the turns they ran in.
///
/// `startup-queue.py mainjobs` launches the app with ``environmentKey`` set and reads ``MainJobCensusReport`` through
/// `debug.startup.main_jobs`. Chrome keeps the same split for its UI thread: tasks by post site, native work around
/// them, and the after-startup tasks by name (chrome/browser/after_startup_task_utils.cc).
///
/// Debug and bench-hooks builds only; armed only by ``environmentKey``, so the startup benches measure a launch
/// without it. Recording stops at startup completion (``freeze(after:)``), and every buffer is preallocated.
///
/// `CMUX_NEXT_MAIN_JOB_CENSUS=input` arms the input window instead (sequence-manager-DESIGN.md 2.7, step S6): a
/// continuous ring that is never frozen and has no turn observers. At each key or click dispatch the app notes the
/// event (``MainJobRing/noteInputDispatch(eventNanos:dispatchNanos:)``), and `debug.main_jobs.input` reports the main
/// jobs that ran between each event's arrival and its dispatch, by enqueue site (``MainJobInputReport``). Its rig
/// (``storm(tasks:interval:work:duration:)``) makes a storm of main-actor awaits to measure under.
///
/// ```swift
/// let census = MainJobCensus.armed(environment: ProcessInfo.processInfo.environment, processStartNanos: start)
/// census?.freeze(after: order.startup)
/// // later, on main: the copy; off main: the report
/// let snapshot = census.snapshot(mainTasks: MainJobCensus.mainTasks(startup.log))
/// let report = MainJobCensusReport(snapshot, symbolize: frames)
/// ```
@MainActor
public final class MainJobCensus {
    /// `CMUX_NEXT_MAIN_JOB_CENSUS=1` arms the census for one launch.
    public nonisolated static let environmentKey = "CMUX_NEXT_MAIN_JOB_CENSUS"
    /// The jobs the ring keeps (about 1 MB).
    public nonisolated static let jobCapacity = 8_192
    /// ``environmentKey``'s value that arms the input window.
    public nonisolated static let inputWindowValue = "input"
    /// The input window's ring: the main jobs queued and not run yet that it tracks (about 3 MB; the window's own
    /// preallocated storage is about 16 MB more).
    public nonisolated static let inputJobCapacity = 16_384

    /// One StartupScheduler task that ran on the main thread.
    public struct TaskSpan: Sendable, Equatable {
        public var name: String
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        public var startNanos: UInt64
        public var durationNanos: UInt64

        public init(name: String, startNanos: UInt64, durationNanos: UInt64) {
            self.name = name
            self.startNanos = startNanos
            self.durationNanos = durationNanos
        }
    }

    /// A copy of what the census holds, taken on the main thread; the report is built from it off the main thread.
    public struct Snapshot: Sendable {
        public var hook: MainJobRing.HookState
        public var processStartNanos: UInt64
        public var frozen: Bool
        public var jobs: [MainJobRing.Job]
        public var pendingJobs: Int
        public var droppedJobs: Int
        public var segments: MainTurnSegments
        public var tasks: [TaskSpan]
    }

    /// What the ring's install found.
    public let hook: MainJobRing.HookState
    /// Armed with ``inputWindowValue``: the input window, not the launch's census.
    public var isInputWindow: Bool { ring.continuous }
    public private(set) var frozen = false
    private let ring: MainJobRing
    private let processStartNanos: UInt64
    private var segments: MainTurnSegments
    private var observers: [MainRunLoopObserver] = []

    /// The census `environment` asks for, its ring installed and its observers on the main run loop; nil when
    /// ``environmentKey`` is neither `1` nor ``inputWindowValue``. Call first thing in `main`, while the process has one thread.
    public static func armed(environment: [String: String], processStartNanos: UInt64) -> MainJobCensus? {
        if environment[environmentKey] == inputWindowValue {
            let ring = MainJobRing(capacity: inputJobCapacity, continuous: true)
            return MainJobCensus(ring: ring, hook: ring.install(), processStartNanos: processStartNanos)
        }
        guard environment[environmentKey] == "1" else { return nil }
        let ring = MainJobRing(capacity: jobCapacity)
        let census = MainJobCensus(ring: ring, hook: ring.install(), processStartNanos: processStartNanos)
        census.observe()
        return census
    }

    /// A census over `ring` (tests pass a ring that is not installed and drive ``record(_:at:)`` themselves).
    public init(ring: MainJobRing, hook: MainJobRing.HookState, processStartNanos: UInt64) {
        self.ring = ring
        self.hook = hook
        self.processStartNanos = processStartNanos
        segments = MainTurnSegments(startingAt: ring.now)
    }

    /// Adds the two observers: the first observer of every stage, and the last of before-waiting and exit, so the
    /// display cycle and the commit (and every other observer) run inside the turn.
    private func observe() {
        let first = MainRunLoopObserver(activities: [.entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit],
                                        order: .min) { [weak self] activity in
            switch activity {
            case .entry: self?.record(.entry)
            case .beforeTimers: self?.record(.beforeTimers)
            case .beforeSources: self?.record(.beforeSources)
            case .beforeWaiting: self?.record(.beforeWaiting)
            case .afterWaiting: self?.record(.afterWaiting)
            default: self?.record(.exit)
            }
        }
        let last = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: .max) { [weak self] activity in
            self?.record(activity == .exit ? .exited : .rendered)
        }
        observers = [first, last]
    }

    /// Records a run-loop stage now.
    public func record(_ activity: MainTurnSegments.Activity) {
        record(activity, at: ring.now)
    }

    /// Records a run-loop stage at `now`, with the jobs the ring timed since the last stage.
    public func record(_ activity: MainTurnSegments.Activity, at now: UInt64) {
        guard !frozen else { return }
        segments.record(activity, at: now, jobs: ring.takeTally())
    }

    /// Stops recording: the ring takes no more jobs and the observers are removed.
    public func freeze() {
        guard !frozen else { return }
        frozen = true
        ring.freeze()
        observers = []
    }

    /// Freezes the census when `startup` completes; the input window records on.
    public func freeze(after startup: StartupScheduler) {
        guard !isInputWindow else { return }
        startup.whenComplete { [weak self] _ in self?.freeze() }
    }

    /// The input window now (``isInputWindow``), copied on the main thread; ``MainJobInputReport`` names its sites.
    public func inputWindow() -> MainJobRing.InputWindow { ring.readInputWindow() }

    /// Empties the input window.
    public func resetInputWindow() { ring.resetInputWindow() }

    /// The rig's storm of main-actor awaits: `tasks` main-actor tasks that each, for `duration`, await an off-main call
    /// that waits `interval`, then spend `work` on the main thread. Each turn of a task is one unposted main-actor job,
    /// the await's resume enqueued from the pool, the kind that stays FIFO on the main queue (sequence-manager-DESIGN.md
    /// 2.7). Returns the jobs a second it asks for.
    @discardableResult
    public func storm(tasks: Int, interval: Duration, work: Duration, duration: Duration) -> Double {
        let end = ContinuousClock.now + duration
        for _ in 0 ..< max(0, tasks) {
            // main-hop-allow: the census rig's storm is unposted main-actor work on purpose (Debug and bench builds only); a class would remove what it measures
            Task(priority: .userInitiated) { @MainActor in
                while ContinuousClock.now < end {
                    await Self.offMain(waiting: interval)
                    let busy = ContinuousClock.now + work
                    while ContinuousClock.now < busy {}
                }
            }
        }
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        return seconds > 0 ? Double(max(0, tasks)) / seconds : 0
    }

    /// One await that leaves the main actor, waits `interval` on the pool, and resumes on the caller's actor.
    @concurrent
    nonisolated static func offMain(waiting interval: Duration) async {
        // wakeup-allow: the census rig's storm paces its awaits (Debug and bench builds, only for `debug.main_jobs.input storm`, ends after its duration); it runs on the pool (@concurrent), never on main
        try? await Task.sleep(for: interval)
    }

    /// What the census holds now, with the StartupScheduler's main tasks (``mainTasks(_:)``).
    public func snapshot(mainTasks: [TaskSpan]) -> Snapshot {
        let (jobs, pending, dropped) = ring.read()
        return Snapshot(hook: hook, processStartNanos: processStartNanos, frozen: frozen, jobs: jobs,
                        pendingJobs: pending, droppedJobs: dropped, segments: segments, tasks: mainTasks)
    }

    /// The tasks of `log` that ran on the main thread and ended.
    public nonisolated static func mainTasks(_ log: StartupTaskLog) -> [TaskSpan] {
        log.records.compactMap { record in
            guard record.destination == .main, let start = record.startNanos, let duration = record.durationNanos else { return nil }
            return TaskSpan(name: "\(record.name)", startNanos: start, durationNanos: duration)
        }
    }
}
#endif
