#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// `debug.startup`'s payload (plans/cmux-next/chrome-parity/p08-startup.md, task 008): one launch's
/// milestones, temperature and counters, the StartupScheduler's tasks and completion reason, what the first
/// committed frame held, and the startup trace's ring size. The bench (`bench-startup.py`) and the startup
/// queues (`startup-queue.py`) read it after each launch.
///
/// Chrome keeps the same launch record in `startup_metric_utils`
/// (components/startup_metric_utils/browser/startup_metric_utils.cc: the milestones and the temperature)
/// and per after-startup task in chrome/browser/after_startup_task_utils.cc. A Debug and bench-hooks type
/// only: a Release build has no `debug.startup`, so it carries none of this.
///
/// A field whose producer has not run (or is not wired in this build) encodes as `null`, never as an
/// empty or zero value: `"tasks": null` is "no scheduler", `"tasks": []` is "nothing was posted".
///
/// ```swift
/// var report = StartupReport(launch: marks, counters: counters) // the launch's LaunchMarks and counter values
/// report.firstFrame = recorder.firstFrame
/// let reply = try report.foundationObject()
/// ```
public nonisolated struct StartupReport: Sendable, Equatable, Encodable {
    /// The temperature's value mark, `launch.temperature <name>` (task 007).
    public static let temperatureValue = "launch.temperature"
    /// The value mark of the page-ins at `run_loop_start` (task 007).
    public static let pageInsRunLoopStart = "launch.pageins_run_loop_start"
    /// The value mark of the page-ins at the first committed frame (task 007).
    public static let pageInsFirstFrame = "launch.pageins_first_frame"
    /// The value mark of the main thread's CPU time at the first committed frame (task 007).
    public static let mainCPUFirstFrame = "launch.main_cpu_ms"
    /// The temperature's other form, an instant mark: this prefix and the temperature's name (task 007).
    public static let temperatureMarkPrefix = "launch.temperature."
    /// The mark of a launch something interrupted (task 108).
    public static let interruptedMark = "launch.interrupted"

    /// The launch counters read so far (task 007's value marks): the temperature by name and each numeric value
    /// by name. Nil in a report means no counter source is wired.
    public nonisolated struct Counters: Sendable, Equatable {
        /// `cold`, `warm`, `lukewarm` or `undetermined`; nil before `run_loop_start` read the page-ins.
        public var temperature: String?
        /// Each numeric value mark (``pageInsRunLoopStart``, ``pageInsFirstFrame``, ``mainCPUFirstFrame``) by name.
        public var values: [String: Double]

        public init(temperature: String? = nil, values: [String: Double] = [:]) {
            self.temperature = temperature
            self.values = values
        }

        /// Keeps one value mark as the bench's pipe carries it (`<name> <value>`): ``temperatureValue``'s name,
        /// or a number. The first value of each name stays; a value that is not a number is dropped.
        public mutating func record(_ name: String, value: String) {
            if name == StartupReport.temperatureValue {
                if temperature == nil { temperature = value }
            } else if values[name] == nil, let number = Double(value) {
                values[name] = number
            }
        }
    }

    /// A launch mark: its name and milliseconds since process start.
    public nonisolated struct Milestone: Sendable, Equatable {
        public var name: String
        public var ms: Double

        public init(name: String, ms: Double) {
            self.name = name
            self.ms = ms
        }
    }

    /// One StartupScheduler task posted before completion. Times are milliseconds since process start.
    public nonisolated struct TaskRecord: Sendable, Equatable, Encodable {
        public var name: String
        /// `critical`, `afterFirstFrame`, `afterStartup` or `onDemand`.
        public var priority: String
        /// `main`, or the lane and its work priority.
        public var destination: String
        public var postedMs: Double
        /// Nil until the task starts.
        public var startMs: Double?
        /// Nil until the task ends.
        public var durationMs: Double?
        /// The startup rule the post broke, nil when it broke none.
        public var violation: String?

        public init(name: String, priority: String, destination: String, postedMs: Double,
                    startMs: Double? = nil, durationMs: Double? = nil, violation: String? = nil) {
            self.name = name
            self.priority = priority
            self.destination = destination
            self.postedMs = postedMs
            self.startMs = startMs
            self.durationMs = durationMs
            self.violation = violation
        }

        /// A task recorded on the `CLOCK_UPTIME_RAW` nanosecond clock, as milliseconds since process start.
        public init(name: String, priority: String, destination: String, processStartNanos: UInt64,
                    postedNanos: UInt64, startNanos: UInt64?, durationNanos: UInt64?, violation: String?) {
            self.init(name: name, priority: priority, destination: destination,
                      postedMs: StartupReport.milliseconds(sinceProcessStart: processStartNanos, at: postedNanos),
                      startMs: startNanos.map { StartupReport.milliseconds(sinceProcessStart: processStartNanos, at: $0) },
                      durationMs: durationNanos.map { StartupReport.rounded(Double($0) / 1_000_000) },
                      violation: violation)
        }

        private enum CodingKeys: String, CodingKey {
            case name, priority, destination, violation
            case postedMs = "posted_ms", startMs = "start_ms", durationMs = "duration_ms"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(priority, forKey: .priority)
            try container.encode(destination, forKey: .destination)
            try container.encode(postedMs, forKey: .postedMs)
            try container.encode(startMs, forKey: .startMs)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(violation, forKey: .violation)
        }
    }

    /// What the StartupScheduler recorded: its tasks in post order, and why startup completed.
    public nonisolated struct Scheduler: Sendable, Equatable {
        public var tasks: [TaskRecord]
        /// The completion reason (`refsReleased`, `failsafe`, ...), nil before completion.
        public var completionReason: String?

        public init(tasks: [TaskRecord], completionReason: String?) {
            self.tasks = tasks
            self.completionReason = completionReason
        }
    }

    /// One thread of the process.
    public nonisolated struct ThreadRecord: Sendable, Equatable, Encodable {
        /// The kernel's thread ID (`THREAD_IDENTIFIER_INFO`).
        public var id: UInt64
        /// `pthread_setname_np`'s name as the kernel holds it; empty when unnamed.
        public var name: String
        /// The scheduling priority now (`pth_curpri`).
        public var priority: Int32
        public var isMain: Bool

        public init(id: UInt64, name: String, priority: Int32, isMain: Bool) {
            self.id = id
            self.name = name
            self.priority = priority
            self.isMain = isMain
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, priority
            case isMain = "main"
        }
    }

    /// What the first window's first committed frame held.
    public nonisolated struct FirstFrame: Sendable, Equatable {
        /// The type names of the window content view's subviews, back to front; nil when the window had no
        /// content view (unknown, not "no subviews").
        public var layerTree: [String]?
        /// The pane views built when the frame committed.
        public var viewsBuilt: Int
        /// The process's threads, read off the main thread right after the frame committed; nil until that
        /// read lands.
        public var threads: [ThreadRecord]?

        public init(layerTree: [String]?, viewsBuilt: Int, threads: [ThreadRecord]? = nil) {
            self.layerTree = layerTree
            self.viewsBuilt = viewsBuilt
            self.threads = threads
        }
    }

    /// The launch marks in the order they were recorded.
    public var milestones: [Milestone]
    /// The launch's counters; nil when this build wires no counter source into the report.
    public var counters: Counters?
    /// Nil when this build wires no StartupScheduler into the report.
    public var scheduler: Scheduler?
    /// Nil until the first frame committed.
    public var firstFrame: FirstFrame?
    /// The startup trace's preallocated ring, 0 with no trace (`CMUX_TRACE_STARTUP` unset).
    public var traceRingBytes: Int
    /// The main thread's wait for the action catalog's launch build; nil until the main thread read it.
    public var actionCatalogMainWaitMs: Double?

    public init(milestones: [Milestone], counters: Counters? = nil, scheduler: Scheduler? = nil,
                firstFrame: FirstFrame? = nil, traceRingBytes: Int, actionCatalogMainWaitMs: Double? = nil) {
        self.milestones = milestones
        self.counters = counters
        self.scheduler = scheduler
        self.firstFrame = firstFrame
        self.traceRingBytes = traceRingBytes
        self.actionCatalogMainWaitMs = actionCatalogMainWaitMs
    }

    /// The marks `launch` recorded so far with its startup trace's ring size, and the counters read so far.
    public init(launch: LaunchMarks, counters: Counters?) {
        self.init(milestones: launch.all.map { Milestone(name: $0.name, ms: $0.ms) }, counters: counters,
                  traceRingBytes: launch.trace?.ringBytes ?? 0)
    }

    /// The report as a `JSONSerialization` object graph, the control reply's form.
    public func foundationObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }

    /// The temperature `run_loop_start` decided (`cold`, `warm`, `lukewarm`, `undetermined`): the counters'
    /// value mark, else the instant mark `launch.temperature.<name>` (bench-startup.py reads both the same way);
    /// nil before it, or in a build that reads no page-ins.
    public var temperature: String? {
        counters?.temperature ?? milestones.first { $0.name.hasPrefix(Self.temperatureMarkPrefix) }
            .map { String($0.name.dropFirst(Self.temperatureMarkPrefix.count)) }
    }

    /// Whether something interrupted the launch (its numbers are not a launch's).
    public var interrupted: Bool { milestones.contains { $0.name == Self.interruptedMark } }

    /// The posts that broke a startup rule (an unlisted critical name, an onDemand post); nil with no scheduler.
    public var criticalViolations: Int? { scheduler.map { $0.tasks.count(where: { $0.violation != nil }) } }

    /// Milliseconds from `processStartNanos` to `nanos` on the `CLOCK_UPTIME_RAW` clock, to 0.001 ms; a
    /// time before process start is 0.
    public static func milliseconds(sinceProcessStart processStartNanos: UInt64, at nanos: UInt64) -> Double {
        rounded(Double(nanos > processStartNanos ? nanos - processStartNanos : 0) / 1_000_000)
    }

    /// `ms` to the microsecond.
    static func rounded(_ ms: Double) -> Double { (ms * 1_000).rounded() / 1_000 }

    private enum CodingKeys: String, CodingKey {
        case milestones, interrupted, temperature, tasks, reason
        case pageInsRunLoopStart = "pageins_run_loop_start"
        case pageInsFirstFrame = "pageins_first_frame"
        case mainCPUFirstFrame = "main_cpu_ms_to_first_frame"
        case criticalViolations = "critical_violations"
        case viewsBuilt = "views_built"
        case firstCommitLayerTree = "first_commit_layer_tree"
        case threadsAtFirstFrame = "threads_at_first_frame"
        case traceRingBytes = "trace_ring_bytes"
        case actionCatalogMainWaitMs = "action_catalog_main_wait_ms"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // An object, as startup-queue.py reads it: each name once (LaunchMarks keeps the first).
        var marks: [String: Double] = [:]
        for milestone in milestones where marks[milestone.name] == nil { marks[milestone.name] = Self.rounded(milestone.ms) }
        try container.encode(marks, forKey: .milestones)
        try container.encode(interrupted, forKey: .interrupted)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(counters?.values[Self.pageInsRunLoopStart], forKey: .pageInsRunLoopStart)
        try container.encode(counters?.values[Self.pageInsFirstFrame], forKey: .pageInsFirstFrame)
        try container.encode(counters?.values[Self.mainCPUFirstFrame].map(Self.rounded), forKey: .mainCPUFirstFrame)
        try container.encode(scheduler?.tasks, forKey: .tasks)
        try container.encode(criticalViolations, forKey: .criticalViolations)
        try container.encode(scheduler?.completionReason, forKey: .reason)
        try container.encode(firstFrame?.viewsBuilt, forKey: .viewsBuilt)
        try container.encode(firstFrame?.layerTree, forKey: .firstCommitLayerTree)
        try container.encode(firstFrame?.threads, forKey: .threadsAtFirstFrame)
        try container.encode(traceRingBytes, forKey: .traceRingBytes)
        try container.encode(actionCatalogMainWaitMs.map(Self.rounded), forKey: .actionCatalogMainWaitMs)
    }
}
#endif
