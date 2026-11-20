public import CmuxNextSettings
public import CmuxNextWakeups
public import Darwin
import Foundation
import os
import CmuxNextCompat

/// Records a "busy" entry in the `debug.hangs` ring buffer when the main
/// thread, the whole process, or a helper process (Chromium) uses CPU above
/// a threshold for a whole window (default 10 s) while nothing explains it:
/// no input, no animation frame, no terminal output
/// (plans/cmux-next/idle-wakeups.md). The record carries a main-thread stack
/// sample and the busiest WakeupLedger owners.
///
/// It is demand-driven: a window opens when the main run loop wakes
/// (``noteAwake()``) and ends with one ``DemandTimer`` deadline; a new window
/// opens at once only if the app was awake during the last one. An idle app
/// therefore costs nothing, and a steadily busy app one check per window.
/// A spin on a background thread that never wakes the main thread is seen
/// only in the window after the last main-thread wake.
///
/// It watches the main thread, so it never blocks it: every kernel read (each
/// process's `proc_pid_rusage` and `proc_pidinfo`, the helper list, the main
/// thread's `thread_info` and its stack sample) runs on its own serial queue
/// (`com.cmuxterm.next.busy-watchdog`, threading-model.md). The main thread's part is ``noteAwake()``: two
/// atomics, and one queue hop when it opens a window. v229 (2026-10-30): a
/// window end on the main thread stalled it 1,261 ms in `proc_pidinfo`.
public final class BusyWatchdog: Sendable {
    public struct Configuration: Sendable {
        public var window: Duration
        /// CPU share of one core (1.0 = 100%) above which a window is busy.
        public var mainThreadThreshold: Double
        public var processThreshold: Double
        public var helperThreshold: Double
        public var logBusy: Bool

        public init(window: Duration = .seconds(10), mainThreadThreshold: Double = 0.3, processThreshold: Double = 0.5,
                    helperThreshold: Double = 0.5, logBusy: Bool = ControlService.isDebugBuild) {
            self.window = window
            self.mainThreadThreshold = mainThreadThreshold
            self.processThreshold = processThreshold
            self.helperThreshold = helperThreshold
            self.logBusy = logBusy
        }
    }

    /// A helper process to watch, with what it serves (tab title, URL).
    public struct Helper: Sendable {
        public var pid: pid_t
        public var label: String
        public init(pid: pid_t, label: String) {
            self.pid = pid
            self.label = label
        }
    }

    /// What the watchdog reads from the kernel: each read is a system call that can block for as long as the
    /// kernel holds the process (`proc_pid_rusage`, `proc_pidinfo`, `thread_info`).
    struct Probe: Sendable {
        /// One process's cumulative CPU time and wakeups; nil when it is gone.
        var usage: @Sendable (pid_t) -> ProcessUsage?
        /// One thread's CPU time (user + system) in ns; nil when `thread_info` fails.
        var threadCPUNanos: @Sendable (thread_act_t) -> UInt64?

        /// The kernel's answers.
        static let system = Probe(usage: { ProcessUsage.sample($0) }, threadCPUNanos: { BusyWatchdog.cpuNanos(of: $0) })
    }

    public let configuration: Configuration
    private let probe: Probe
    private let log: HangLog
    private let ledger: WakeupLedger
    private let activity: ExpectedActivity
    private let helpers: Mutex<HelperSource>
    private let mainThread: Mutex<thread_act_t?> = Mutex(nil)
    private let sampler: Mutex<ThreadStackSampler?> = Mutex(nil)
    private let measuring = Atomic<Bool>(false)
    private let awakeDuringWindow = Atomic<Bool>(false)
    private let window: Mutex<Window?> = Mutex(nil)
    private let timer: DemandTimer
    /// Runs every open and close, so every kernel read: serial, so a window's close follows its open. At
    /// most one open or close is pending (``measuring`` admits one window at a time, its deadline one close),
    /// so the queue needs no bound; a read the kernel holds delays only the next window.
    private let sampling = DispatchQueue(label: "com.cmuxterm.next.busy-watchdog", qos: .utility)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hangs")

    /// A value wrapper prevents inout Mutex reads from reabstracting and
    /// writing back the function, accumulating a thunk on every read.
    private struct HelperSource: Sendable {
        let list: @Sendable () -> [Helper]
    }

    struct Window {
        var process: ProcessUsage?
        var mainCPUNanos: UInt64
        var activity: UInt64
        var helpers: [pid_t: (label: String, usage: ProcessUsage)]
        var startNanos: UInt64
    }

    public convenience init(configuration: Configuration = Configuration(), log: HangLog, ledger: WakeupLedger = .shared,
                            activity: ExpectedActivity = .shared, clock: any Clock<Duration> = ContinuousClock()) {
        self.init(configuration: configuration, log: log, ledger: ledger, activity: activity, clock: clock, probe: .system)
    }

    /// The seam initializer: `probe` reads the kernel (tests record where each read runs).
    init(configuration: Configuration, log: HangLog, ledger: WakeupLedger, activity: ExpectedActivity,
         clock: any Clock<Duration>, probe: Probe) {
        self.configuration = configuration
        self.probe = probe
        self.log = log
        self.ledger = ledger
        self.activity = activity
        self.helpers = Mutex(HelperSource(list: { [] }))
        self.timer = DemandTimer(owner: "BusyWatchdog.window", clock: clock, ledger: ledger)
    }

    /// Sets the thread whose CPU and stack are watched (call on the main thread).
    public func watchCurrentThread() {
        let thread = mach_thread_self()
        mainThread.withLock { $0 = thread }
        sampler.withLock { $0 = ThreadStackSampler(thread: thread) }
    }

    /// Supplies the helper processes to watch (the App lists Chromium helpers).
    public func setHelperSource(_ source: @escaping @Sendable () -> [Helper]) {
        helpers.withLock { $0 = HelperSource(list: source) }
    }

    /// Snapshots the callback under the lock, for invocation after releasing it.
    func helperSource() -> @Sendable () -> [Helper] {
        helpers.withLock { $0.list }
    }

    /// The main run loop woke. Cheap, and it never reads the kernel: two
    /// atomics, and when no window is open one hop that opens it on the
    /// sampling queue.
    public func noteAwake() {
        guard measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            awakeDuringWindow.store(true, ordering: .relaxed)
            return
        }
        // This wake opens the window; it is not a wake during it. The expected-activity count is stamped here, in
        // the waking turn (atomic loads, no system call), so input in this turn counts as during the window.
        awakeDuringWindow.store(false, ordering: .relaxed)
        let activityAtWake = activity.total
        sampling.async { [self] in openWindow(activity: activityAtWake) }
    }

    /// Takes the window's start samples. On the sampling queue. `activity`: the expected-activity count when the
    /// window began (the waking turn's stamp, or the close's for a window that follows one).
    private func openWindow(activity activityAtStart: UInt64) {
        let helperList = helperSource()()
        var sampled: [pid_t: (label: String, usage: ProcessUsage)] = [:]
        for helper in helperList {
            if let usage = probe.usage(helper.pid) { sampled[helper.pid] = (helper.label, usage) }
        }
        let start = Window(process: probe.usage(getpid()), mainCPUNanos: mainCPUNanos(), activity: activityAtStart,
                           helpers: sampled, startNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        window.withLock { $0 = start }
        timer.schedule(after: configuration.window) { [weak self] in self?.endWindow() }
    }

    /// The window's deadline fired: its close runs on the sampling queue.
    private func endWindow() {
        sampling.async { [self] in closeWindow() }
    }

    /// Takes the window's end samples, records a busy window, and opens the next window when the app woke
    /// during this one. On the sampling queue.
    private func closeWindow() {
        guard let start = window.withLock({ window in defer { window = nil }; return window }) else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wall = Double(max(now &- start.startNanos, 1))
        let activityAtEnd = activity.total
        let quiet = activityAtEnd == start.activity
        if quiet {
            let mainShare = Double(mainCPUNanos() &- start.mainCPUNanos) / wall
            let process = probe.usage(getpid())
            let processShare = process.flatMap { end in start.process.map { end.cpuShare(since: $0) } } ?? 0
            if mainShare > configuration.mainThreadThreshold || processShare > configuration.processThreshold {
                let addresses = sampler.withLock { $0?.sample() } ?? []
                record(scope: mainShare > configuration.mainThreadThreshold ? "main-thread" : "process",
                       pid: getpid(), name: process?.name ?? "app", label: nil, share: max(mainShare, processShare),
                       wall: wall, addresses: addresses)
            }
            for (pid, entry) in start.helpers {
                guard let usage = probe.usage(pid) else { continue }
                let share = usage.cpuShare(since: entry.usage)
                if share > configuration.helperThreshold {
                    record(scope: "helper", pid: pid, name: usage.name, label: entry.label, share: share, wall: wall, addresses: [])
                }
            }
        }
        // Keep watching only while the app stays awake. The next window starts with no wake counted.
        if awakeDuringWindow.exchange(false, ordering: .relaxed) {
            openWindow(activity: activityAtEnd)
            return
        }
        measuring.store(false, ordering: .releasing)
        // A wake between the exchange and the store found the watch still on and opened nothing: open for it.
        if awakeDuringWindow.exchange(false, ordering: .relaxed),
           measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            openWindow(activity: activityAtEnd)
        }
    }

    private func record(scope: String, pid: pid_t, name: String, label: String?, share: Double, wall: Double, addresses: [UInt]) {
        let top = ledger.snapshot().prefix(8).map { entry -> JSONValue in
            ["owner": .string(entry.owner), "reason": .string(entry.reason), "per_second": .number(entry.perSecond)]
        }
        var details: [String: JSONValue] = [
            "scope": .string(scope), "pid": JSONValue(Int(clamping: pid)), "process": .string(name),
            "cpu_share": .number(share), "wakeups": .array(top),
        ]
        if let label { details["serves"] = .string(label) }
        let duration = Duration.nanoseconds(wall.saturatedInteger(Int64.self) ?? 0)
        let record = log.append(startUptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- (wall.saturatedInteger(UInt64.self) ?? 0), duration: duration,
                                cpu: .nanoseconds((share * wall).saturatedInteger(Int64.self) ?? 0), addresses: addresses, kind: .busy, details: details)
        if configuration.logBusy {
            logger.error("busy \(scope, privacy: .public) \(name, privacy: .public) at \(share * 100, format: .fixed(precision: 0))% CPU for \(wall / 1e9, format: .fixed(precision: 1)) s with no input, animation or output (hang \(record.sequence); see debug.hangs)")
        }
    }

    private func mainCPUNanos() -> UInt64 { mainThreadCPUNanos() ?? 0 }

    /// The watched thread's CPU time (user + system), from any thread; nil
    /// before ``watchCurrentThread()`` or when `thread_info` fails.
    func mainThreadCPUNanos() -> UInt64? {
        guard let thread = mainThread.withLock({ $0 }) else { return nil }
        return probe.threadCPUNanos(thread)
    }

    /// `thread`'s CPU time (user + system) from `thread_info`, from any thread; nil when it fails.
    static func cpuNanos(of thread: thread_act_t) -> UInt64? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(clamping: info.user_time.seconds) * 1_000_000_000 + UInt64(clamping: info.user_time.microseconds) * 1_000
        let system = UInt64(clamping: info.system_time.seconds) * 1_000_000_000 + UInt64(clamping: info.system_time.microseconds) * 1_000
        return user + system
    }
}
