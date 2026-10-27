import CmuxNextCompat
import Darwin

/// `memory.<kind>_kib`, `memory.total_kib`, `cpu.<kind>_pct` and `disk.idle_write_kib_per_min` for the cmux processes
/// the app knows (plans/cmux-next/chrome-parity/p09-observability.md, task 121).
///
/// Chrome records the same per process type: `Memory.<Process>.PrivateMemoryFootprint` per process and
/// `Memory.Total.PrivateMemoryFootprint` once (chrome/browser/metrics/process_memory_metrics_emitter.cc), and
/// `PerformanceMonitor.AverageCPU2.<ProcessType>` (chrome/browser/performance_monitor/process_monitor.cc). Chrome
/// samples on a timer; cmux samples only at transitions (the app resigning or becoming active, a report), so an idle
/// app pays no wakeup for its own numbers, and the pids come from the app's known sources (its own pid, its Chromium
/// helpers, the daemon and what the daemon reports), never a scan of process names.
///
/// One sample reads `proc_pid_rusage` once per known process (``Sources/live``) and records:
/// - `memory.<kind>_kib`: each process's physical footprint (`ri_phys_footprint`), one sample per process;
/// - `memory.total_kib`: the sum over every process read, once;
/// - `cpu.<kind>_pct`: each process's CPU time since its previous reading, in percent of one core, when that reading
///   is at least ``minimumCPUPeriodNanos`` old and is the same process (its start time tells a reused pid apart);
///   a younger baseline stays, so a quick switch back and forth records nothing and loses nothing;
/// - `disk.idle_write_kib_per_min`: the bytes written (`ri_diskio_byteswritten`) per idle minute by the processes
///   known at both ends of an idle period. A period opens when the app resigns active and closes when it becomes
///   active; a report records the period so far and opens the next. A period under ``minimumIdlePeriodNanos``
///   records nothing (at a report it stays open).
///
/// The reads are system calls: call ``sample(_:at:)`` off the main thread. Transitions carry a sequence number from the
/// caller's own order, and a sample older than one already applied is dropped, so two samples that ran on a lane out
/// of order never open an idle period while the app is active.
///
/// ```swift
/// let sampler = ProcessResourceSampler()
/// sampler.sample([.init(kind: .app, pid: getpid())], at: .init(trigger: .resignActive, sequence: 1))
/// ```
public final class ProcessResourceSampler: Sendable {
    /// The shortest CPU period that records: 10 s of uptime.
    public static let minimumCPUPeriodNanos: UInt64 = 10 * 1_000_000_000
    /// The shortest idle period that records disk writes: one minute, as `idle.wakeups` (task 059).
    public static let minimumIdlePeriodNanos: UInt64 = 60 * 1_000_000_000

    public typealias Kind = HistogramID.ProcessKind

    /// What caused a sample.
    public enum Trigger: Int, Sendable, CaseIterable {
        /// The app stopped being the active app: an idle period opens.
        case resignActive
        /// The app became the active app: the idle period closes.
        case becomeActive
        /// A report is about to read the histograms.
        case report

        /// The trigger's name in reports.
        public var name: String {
            switch self {
            case .resignActive: "resign_active"
            case .becomeActive: "become_active"
            case .report: "report"
            }
        }
    }

    /// One transition: its trigger and its place in the caller's order (larger is later).
    public struct Transition: Sendable, Equatable {
        public var trigger: Trigger
        public var sequence: UInt64

        public init(trigger: Trigger, sequence: UInt64) {
            self.trigger = trigger
            self.sequence = sequence
        }
    }

    /// A process the app knows, with the kind its histograms are named by.
    public struct KnownProcess: Sendable, Hashable {
        public var kind: Kind
        public var pid: Int32

        public init(kind: Kind, pid: Int32) {
            self.kind = kind
            self.pid = pid
        }
    }

    /// One process's counters (cumulative since it started).
    public struct Usage: Sendable, Equatable {
        /// The physical footprint in bytes (`ri_phys_footprint`, Activity Monitor's Memory).
        public var footprintBytes: UInt64
        /// User plus system CPU time in ns.
        public var cpuNanos: UInt64
        /// Bytes written to disk (`ri_diskio_byteswritten`).
        public var diskWriteBytes: UInt64
        /// When the process started (`ri_proc_start_abstime`): two reads of one pid with different starts are two
        /// processes.
        public var startTime: UInt64

        public init(footprintBytes: UInt64, cpuNanos: UInt64, diskWriteBytes: UInt64, startTime: UInt64) {
            self.footprintBytes = footprintBytes
            self.cpuNanos = cpuNanos
            self.diskWriteBytes = diskWriteBytes
            self.startTime = startTime
        }
    }

    /// Where the sampler reads (the tests' seam).
    public struct Sources: Sendable {
        /// `CLOCK_UPTIME_RAW` in ns: it stops while the Mac sleeps, as the processes do.
        public var uptimeNanos: @Sendable () -> UInt64
        /// A process's counters; nil when it ended or is not ours.
        public var usage: @Sendable (Int32) -> Usage?

        public init(uptimeNanos: @escaping @Sendable () -> UInt64, usage: @escaping @Sendable (Int32) -> Usage?) {
            self.uptimeNanos = uptimeNanos
            self.usage = usage
        }

        /// The uptime clock and ``ProcessResourceSampler/usage(of:)``.
        public static let live = Sources(uptimeNanos: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                                         usage: { ProcessResourceSampler.usage(of: $0) })
    }

    /// What one sample recorded.
    public struct Sample: Sendable, Equatable {
        /// The footprint per kind in KiB, summed over the kind's processes.
        public var memoryKiB: [Kind: Int64] = [:]
        /// The footprint of every process read, in KiB.
        public var totalKiB: Int64 = 0
        /// Each process whose CPU recorded, with its percent of one core.
        public var cpuPercent: [KnownProcess: Int64] = [:]
        /// The idle period that recorded disk writes, if one did.
        public var idle: IdlePeriod?
        /// The processes that could not be read (ended, not ours).
        public var unreadable = 0

        public init() {}

        /// The kinds that recorded memory, in the catalog's order.
        public var kinds: [Kind] { Kind.allCases.filter { memoryKiB[$0] != nil } }
    }

    /// One idle period's disk writes.
    public struct IdlePeriod: Sendable, Equatable {
        /// Its length in ns of uptime.
        public var nanos: UInt64
        /// Bytes the processes known at both ends wrote in it.
        public var writtenBytes: UInt64

        public init(nanos: UInt64, writtenBytes: UInt64) {
            self.nanos = nanos
            self.writtenBytes = writtenBytes
        }

        /// KiB written per minute, rounded down.
        public var kibPerMinute: Int64 {
            guard nanos > 0 else { return 0 }
            let scaled = (writtenBytes / 1_024).multipliedFullWidth(by: 60_000_000_000)
            guard nanos > scaled.high else { return .max }
            return Int64(clamping: nanos.dividingFullWidth(scaled).quotient)
        }
    }

    /// The samples recorded per trigger and the ones dropped as out of order, since launch.
    public struct Tally: Sendable, Equatable {
        public var recorded: [Trigger: UInt64] = [:]
        public var outOfOrder: UInt64 = 0

        public init(recorded: [Trigger: UInt64] = [:], outOfOrder: UInt64 = 0) {
            self.recorded = recorded
            self.outOfOrder = outOfOrder
        }
    }

    /// A process's identity and counters at one reading.
    private struct Reading: Sendable {
        var startTime: UInt64
        var cpuNanos: UInt64
        var diskWriteBytes: UInt64
        var uptimeNanos: UInt64
    }

    private struct State: Sendable {
        var lastSequence: UInt64?
        /// Each process's CPU baseline, by pid.
        var cpu: [Int32: Reading] = [:]
        /// Where the open idle period began: its uptime and each process's reading; nil while the app is active.
        var idleStart: (uptimeNanos: UInt64, readings: [Int32: Reading])?
        var tally = Tally()
    }

    private let sources: Sources
    private let metrics: Metrics
    private let state = Mutex(State())

    /// - Parameters:
    ///   - sources: The clock and the counters (``Sources/live`` in the app; tests pass a fake).
    ///   - metrics: Where the samples go (the app runtime's metrics file by default).
    public init(sources: Sources = .live, metrics: Metrics = Metrics()) {
        self.sources = sources
        self.metrics = metrics
    }

    /// Whether an idle period is open (the app is inactive).
    public var isMeasuringIdle: Bool { state.withLock { $0.idleStart != nil } }

    /// The samples recorded per trigger since launch.
    public func tally() -> Tally { state.withLock { $0.tally } }

    /// Reads every process of `processes` once (a pid listed twice is read once, under its first kind) and records
    /// its memory and CPU, and the idle period `transition` closes. A transition older than one already applied
    /// records nothing. Blocking system calls: call it off the main thread.
    @discardableResult
    public func sample(_ processes: [KnownProcess], at transition: Transition) -> Sample? {
        var seen = Set<Int32>()
        var read: [(process: KnownProcess, usage: Usage)] = []
        var unreadable = 0
        for process in processes {
            guard process.pid > 0, seen.insert(process.pid).inserted else { continue }
            if let usage = sources.usage(process.pid) { read.append((process, usage)) } else { unreadable += 1 }
        }
        let now = sources.uptimeNanos()
        let readings = Dictionary(read.map { entry in
            (entry.process.pid, Reading(startTime: entry.usage.startTime, cpuNanos: entry.usage.cpuNanos,
                                        diskWriteBytes: entry.usage.diskWriteBytes, uptimeNanos: now))
        }, uniquingKeysWith: { first, _ in first })

        let applied: (cpu: [KnownProcess: Int64], idle: IdlePeriod?)? = state.withLock { state in
            if let last = state.lastSequence, transition.sequence <= last {
                state.tally.outOfOrder &+= 1
                return nil
            }
            state.lastSequence = transition.sequence
            state.tally.recorded[transition.trigger, default: 0] &+= 1
            let cpu = Self.cpuPercent(read.map(\.process), readings: readings, baselines: &state.cpu)
            return (cpu, Self.advanceIdle(&state.idleStart, trigger: transition.trigger, now: now, readings: readings))
        }
        guard let applied else { return nil }

        var sample = Sample()
        sample.unreadable = unreadable
        for (process, usage) in read {
            let kib = Int64(clamping: usage.footprintBytes / 1_024)
            metrics.record(.memory(process.kind), kib)
            sample.memoryKiB[process.kind, default: 0] += kib
            sample.totalKiB += kib
        }
        if !read.isEmpty { metrics.record(.memoryTotal, sample.totalKiB) }
        for (process, percent) in applied.cpu {
            metrics.record(.cpu(process.kind), percent)
        }
        sample.cpuPercent = applied.cpu
        if let idle = applied.idle {
            metrics.record(.diskIdleWrite, idle.kibPerMinute)
            sample.idle = idle
        }
        return sample
    }

    /// Each process's CPU percent since its baseline, and the baselines moved on: a process with no baseline, or one
    /// of another process with its pid, starts one; a baseline under ``minimumCPUPeriodNanos`` old stays. Baselines of
    /// processes not read now are dropped.
    private static func cpuPercent(_ processes: [KnownProcess], readings: [Int32: Reading],
                                   baselines: inout [Int32: Reading]) -> [KnownProcess: Int64] {
        var percents: [KnownProcess: Int64] = [:]
        var next: [Int32: Reading] = [:]
        for process in processes {
            guard let reading = readings[process.pid] else { continue }
            guard let base = baselines[process.pid], base.startTime == reading.startTime, reading.cpuNanos >= base.cpuNanos,
                  reading.uptimeNanos >= base.uptimeNanos else {
                next[process.pid] = reading
                continue
            }
            let wall = reading.uptimeNanos - base.uptimeNanos
            guard wall >= minimumCPUPeriodNanos else {
                next[process.pid] = base
                continue
            }
            let busy = (reading.cpuNanos - base.cpuNanos).multipliedFullWidth(by: 100)
            percents[process] = wall > busy.high ? Int64(clamping: wall.dividingFullWidth(busy).quotient) : .max
            next[process.pid] = reading
        }
        baselines = next
        return percents
    }

    /// Opens, closes or carries the idle period for `trigger`; returns the period that recorded.
    private static func advanceIdle(_ idleStart: inout (uptimeNanos: UInt64, readings: [Int32: Reading])?, trigger: Trigger,
                                    now: UInt64, readings: [Int32: Reading]) -> IdlePeriod? {
        switch trigger {
        case .resignActive:
            if idleStart == nil { idleStart = (now, readings) }
            return nil
        case .becomeActive:
            defer { idleStart = nil }
            guard let start = idleStart else { return nil }
            return idlePeriod(from: start, to: now, readings: readings)
        case .report:
            guard let start = idleStart, let period = idlePeriod(from: start, to: now, readings: readings) else { return nil }
            idleStart = (now, readings)
            return period
        }
    }

    /// The writes from `start` to `now` of the processes read at both ends (the same process: same start time); nil
    /// under ``minimumIdlePeriodNanos``.
    private static func idlePeriod(from start: (uptimeNanos: UInt64, readings: [Int32: Reading]), to now: UInt64,
                                   readings: [Int32: Reading]) -> IdlePeriod? {
        guard now >= start.uptimeNanos, now - start.uptimeNanos >= minimumIdlePeriodNanos else { return nil }
        var written: UInt64 = 0
        for (pid, end) in readings {
            guard let begin = start.readings[pid], begin.startTime == end.startTime, end.diskWriteBytes >= begin.diskWriteBytes else { continue }
            written &+= end.diskWriteBytes - begin.diskWriteBytes
        }
        return IdlePeriod(nanos: now - start.uptimeNanos, writtenBytes: written)
    }

    /// `pid`'s footprint, CPU time, disk writes and start (`proc_pid_rusage`, `RUSAGE_INFO_V4`: one system call that
    /// copies the kernel's counters); nil when the process ended or is not ours.
    public static func usage(of pid: Int32) -> Usage? {
        var info = rusage_info_v4()
        // SAFETY: the pointer is `info`'s, valid for the call; with RUSAGE_INFO_V4 proc_pid_rusage writes one
        // rusage_info_v4 through it, which is what `info` is.
        let status = unsafe withUnsafeMutablePointer(to: &info) { pointer in
            unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                unsafe blockingProcPidRusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        return Usage(footprintBytes: info.ri_phys_footprint, cpuNanos: nanos(ofTicks: info.ri_user_time &+ info.ri_system_time),
                     diskWriteBytes: info.ri_diskio_byteswritten, startTime: info.ri_proc_start_abstime)
    }

    /// The Mach timebase: rusage CPU times are Mach absolute time units.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        // SAFETY: mach_timebase_info writes one mach_timebase_info_data_t into `info`, a local live for the call.
        unsafe mach_timebase_info(&info)
        return info
    }()

    /// `ticks` of Mach absolute time in ns.
    static func nanos(ofTicks ticks: UInt64) -> UInt64 {
        let base = timebase
        guard base.denom != 0, base.numer != base.denom else { return ticks }
        let scaled = ticks.multipliedFullWidth(by: UInt64(base.numer))
        let denom = UInt64(base.denom)
        guard denom > scaled.high else { return .max }
        return denom.dividingFullWidth(scaled).quotient
    }
}
