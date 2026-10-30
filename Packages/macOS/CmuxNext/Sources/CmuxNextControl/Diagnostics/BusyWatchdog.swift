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
/// sample and the busiest WakeupLedger owners. A busy tab renderer's record
/// names the browser tabs it serves (``setTabSource(_:)``, a snapshot the App
/// publishes): every tab whose main frame or any frame it hosts, so same-site
/// tabs on one renderer are all named. Nothing here waits for the main thread.
///
/// It is demand-driven: a window opens when the main run loop wakes
/// (``noteAwake()``) and ends with one ``DemandTimer`` deadline on the main
/// thread's ``MainWakeUpQueue``, `.flexibleNoSooner` with
/// ``Configuration/windowLeeway`` (10 s) of leeway, so the end rides another
/// main wake when there is one (a `PostDelayedTask` with
/// `subtle::DelayPolicy::kFlexibleNoSooner`, base/task/delay_policy.h). Shares
/// are judged over the real elapsed time from the window's start to its close.
/// A new window opens at once only if the app was awake before the window's
/// nominal end; the fire's own wake comes after it and never counts. An idle
/// app therefore costs nothing, and a steadily busy app one check per 10-20 s.
/// A spin on a background thread that never wakes the main thread is seen
/// only in the window after the last main-thread wake.
///
/// It watches the main thread, so it never blocks it: every kernel read (each
/// process's `proc_pid_rusage` and `proc_pidinfo`, the helper list, the main
/// thread's `thread_info` and its stack sample) runs on its own serial queue
/// (`com.cmuxterm.next.busy-watchdog`, threading-model.md), the window's open
/// and close alike. The main thread's part is ``noteAwake()`` (an uptime read,
/// atomics, and one queue hop when it opens a window) and the end's fire (one
/// queue hop). v229 (2026-10-30): a window end on the main thread stalled it
/// 1,261 ms in `proc_pidinfo`.
public final class BusyWatchdog: Sendable {
    public struct Configuration: Sendable {
        /// The shortest window: its end never fires sooner.
        public var window: Duration
        /// How long after ``window`` the end may wait for another main wake to ride.
        public var windowLeeway: Duration
        /// CPU share of one core (1.0 = 100%) above which a window is busy.
        public var mainThreadThreshold: Double
        public var processThreshold: Double
        public var helperThreshold: Double
        public var logBusy: Bool

        public init(window: Duration = .seconds(10), windowLeeway: Duration = .seconds(10), mainThreadThreshold: Double = 0.3,
                    processThreshold: Double = 0.5, helperThreshold: Double = 0.5, logBusy: Bool = ControlService.isDebugBuild) {
            self.window = window
            self.windowLeeway = windowLeeway
            self.mainThreadThreshold = mainThreadThreshold
            self.processThreshold = processThreshold
            self.helperThreshold = helperThreshold
            self.logBusy = logBusy
        }
    }

    /// A helper process to watch, with its kind.
    public struct Helper: Sendable {
        public var pid: pid_t
        public var label: String
        /// A tab renderer's `--renderer-client-id`; nil for every other helper (extension renderers too).
        public var rendererClientID: Int32?

        public init(pid: pid_t, label: String, rendererClientID: Int32? = nil) {
            self.pid = pid
            self.label = label
            self.rendererClientID = rendererClientID
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
    /// The open window's nominal end (uptime ns): only a wake before it keeps the watch going.
    private let windowEnd = Atomic<UInt64>(0)
    /// Uptime ns, the clock of the window and of the wake queue's deadlines.
    private let uptime: @Sendable () -> UInt64
    /// Runs every open and close, so every kernel read, off the main thread (``samplingQueue()``; tests run it inline).
    private let offMain: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let window: Mutex<Window?> = Mutex(nil)
    private let timer: DemandTimer
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hangs")

    /// A value wrapper prevents inout Mutex reads from reabstracting and
    /// writing back the function, accumulating a thunk on every read.
    private struct HelperSource: Sendable {
        let list: @Sendable () -> [Helper]
        /// The browser tabs and their renderers; nil until the App sets it.
        let tabs: (@Sendable () -> [ProcessUsage.TabRenderers])?
    }

    struct Window {
        var process: ProcessUsage?
        var mainCPUNanos: UInt64
        var activity: UInt64
        var helpers: [pid_t: (helper: Helper, usage: ProcessUsage)]
        var startNanos: UInt64
    }

    /// - Parameters:
    ///   - clock: What the window end sleeps on when there is no `wakeUps`.
    ///   - wakeUps: The main thread's deadline queue (`MainWorkScheduler.wakeUps`), which ends each window; nil
    ///     sleeps the end on `clock` and runs it on the main actor.
    public convenience init(configuration: Configuration = Configuration(), log: HangLog, ledger: WakeupLedger = .shared,
                            activity: ExpectedActivity = .shared, clock: any Clock<Duration> = ContinuousClock(),
                            wakeUps: MainWakeUpQueue? = nil) {
        self.init(configuration: configuration, log: log, ledger: ledger, activity: activity, clock: clock, wakeUps: wakeUps,
                  uptime: WakeupLedger.systemUptime, offMain: Self.samplingQueue())
    }

    /// The production watchdog with its window end on `clock` and `probe` reading the kernel (tests record where
    /// each read runs).
    convenience init(configuration: Configuration, log: HangLog, ledger: WakeupLedger, activity: ExpectedActivity,
                     clock: any Clock<Duration>, probe: Probe) {
        self.init(configuration: configuration, log: log, ledger: ledger, activity: activity, clock: clock, wakeUps: nil,
                  uptime: WakeupLedger.systemUptime, offMain: Self.samplingQueue(), probe: probe)
    }

    /// The seam initializer: `uptime` must be the clock of `wakeUps` (tests pass the queue's fake uptime) and
    /// `offMain` runs each open and close (tests run it inline).
    init(configuration: Configuration, log: HangLog, ledger: WakeupLedger, activity: ExpectedActivity,
         clock: any Clock<Duration>, wakeUps: MainWakeUpQueue?, uptime: @escaping @Sendable () -> UInt64,
         offMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void, probe: Probe = .system) {
        self.configuration = configuration
        self.probe = probe
        self.log = log
        self.ledger = ledger
        self.activity = activity
        self.uptime = uptime
        self.offMain = offMain
        self.helpers = Mutex(HelperSource(list: { [] }, tabs: nil))
        // timer-class-allow: the window end has its class: `.flexibleNoSooner` with 10 s leeway on the main
        // thread's MainWakeUpQueue, else off main on `clock` with no queue to join
        self.timer = DemandTimer(owner: Self.windowOwner, policy: .flexibleNoSooner, clock: clock, ledger: ledger,
                                 energy: wakeUps?.energy, wakeUps: wakeUps)
    }

    /// The ledger owner of each window end.
    static let windowOwner = "BusyWatchdog.window"

    /// The watchdog's own queue for every open and close: serial, so a window's close follows its open; utility,
    /// never the main thread or the cooperative pool (a kernel read can block). At most one open or close is
    /// pending (``measuring`` admits one window at a time, its deadline one close), so it needs no bound; a read
    /// the kernel holds delays only the next window. Each production watchdog makes one.
    static func samplingQueue() -> @Sendable (@escaping @Sendable () -> Void) -> Void {
        let queue = DispatchQueue(label: "com.cmuxterm.next.busy-watchdog", qos: .utility)
        return { work in queue.async(execute: work) }
    }

    /// Sets the thread whose CPU and stack are watched (call on the main thread).
    public func watchCurrentThread() {
        let thread = mach_thread_self()
        mainThread.withLock { $0 = thread }
        sampler.withLock { $0 = ThreadStackSampler(thread: thread) }
    }

    /// Supplies the helper processes to watch (the App lists Chromium helpers).
    public func setHelperSource(_ source: @escaping @Sendable () -> [Helper]) {
        helpers.withLock { $0 = HelperSource(list: source, tabs: $0.tabs) }
    }

    /// Supplies the browser tabs with their renderers, so a busy renderer's record names every tab it
    /// serves. Called off the main thread when a window closes with a busy tab renderer:
    /// it returns a published snapshot (``TabRendererDirectory/snapshot()``) and never waits for the main thread.
    public func setTabSource(_ source: @escaping @Sendable () -> [ProcessUsage.TabRenderers]) {
        helpers.withLock { $0 = HelperSource(list: $0.list, tabs: source) }
    }

    /// Snapshots the callback under the lock, for invocation after releasing it.
    func helperSource() -> @Sendable () -> [Helper] {
        helpers.withLock { $0.list }
    }

    /// The tabs the tab source lists, called after releasing the lock; [] without a source.
    func sourceTabs() -> [ProcessUsage.TabRenderers] {
        guard let source = helpers.withLock({ $0.tabs }) else { return [] }
        return source()
    }

    /// The main run loop woke. Cheap, and it never reads the kernel: an uptime read and two atomics, plus one
    /// hop that opens a window off the main thread when none is open.
    public func noteAwake() {
        if uptime() < windowEnd.load(ordering: .acquiring) { awakeDuringWindow.store(true, ordering: .relaxed) }
        guard measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        // The expected-activity count is stamped here, in the waking turn (atomic loads, no system call), so input
        // in this turn counts as during the window.
        let activityAtWake = activity.total
        offMain { [self] in openWindow(activity: activityAtWake) }
    }

    /// Takes the window's start samples. Through ``offMain``. `activity`: the expected-activity count when the
    /// window began (the waking turn's stamp, or the close's for a window that follows one).
    private func openWindow(activity activityAtStart: UInt64) {
        awakeDuringWindow.store(false, ordering: .relaxed)
        let helperList = helperSource()()
        var sampled: [pid_t: (helper: Helper, usage: ProcessUsage)] = [:]
        for helper in helperList {
            if let usage = probe.usage(helper.pid) { sampled[helper.pid] = (helper: helper, usage: usage) }
        }
        let startNanos = uptime()
        let start = Window(process: probe.usage(getpid()), mainCPUNanos: mainCPUNanos(), activity: activityAtStart,
                           helpers: sampled, startNanos: startNanos)
        window.withLock { $0 = start }
        let windowNanos = UInt64(clamping: configuration.window.wholeMilliseconds).saturatingMultiplication(1_000_000)
        windowEnd.store(startNanos.saturatingAddition(windowNanos), ordering: .releasing)
        timer.scheduleOnMain(after: configuration.window, tolerance: configuration.windowLeeway) { [weak self] in
            self?.endWindow()
        }
    }

    /// The window's deadline fired (on the main thread when the end is on the wake queue). The close reads the
    /// kernel and samples the main thread's stack, which the main thread cannot do to itself, so it runs off it.
    private func endWindow() {
        offMain { [weak self] in self?.closeWindow() }
    }

    func closeWindow() {
        guard let start = window.withLock({ window in defer { window = nil }; return window }) else { return }
        // Only a wake before the nominal end counts: the fire's own wake and one the close itself causes do not
        // keep the watch going. The shares use the real elapsed time, up to window + leeway.
        let stayAwake = awakeDuringWindow.load(ordering: .relaxed)
        let now = uptime()
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
                       wall: wall, end: now, addresses: addresses)
            }
            var busy: [(helper: Helper, name: String, share: Double)] = []
            for (pid, entry) in start.helpers {
                guard let usage = probe.usage(pid) else { continue }
                let share = usage.cpuShare(since: entry.usage)
                if share > configuration.helperThreshold { busy.append((helper: entry.helper, name: usage.name, share: share)) }
            }
            // Same-site tabs share a renderer: the record names every tab it serves.
            let tabs = busy.contains { $0.helper.rendererClientID != nil } ? sourceTabs() : []
            for entry in busy {
                let helper = entry.helper
                let served = helper.rendererClientID.map { ProcessUsage.tabs(tabs, servedBy: ProcessUsage.Renderer(pid: helper.pid, clientID: $0)) } ?? []
                record(scope: "helper", pid: helper.pid, name: entry.name, label: helper.label, tabs: served,
                       share: entry.share, wall: wall, end: now, addresses: [])
            }
        }
        // Keep watching only while the app stayed awake during the window.
        if stayAwake {
            openWindow(activity: activityAtEnd)
        } else {
            measuring.store(false, ordering: .releasing)
        }
    }

    /// A busy entry for the window of `wall` ns that ended at uptime `end`. `tabs` are the browser tabs a
    /// busy renderer serves (`tabs`: `{tab, title}` each).
    private func record(scope: String, pid: pid_t, name: String, label: String?, tabs: [ProcessUsage.TabRenderers] = [],
                        share: Double, wall: Double, end: UInt64, addresses: [UInt]) {
        let top = ledger.snapshot().prefix(8).map { entry -> JSONValue in
            ["owner": .string(entry.owner), "reason": .string(entry.reason), "per_second": .number(entry.perSecond)]
        }
        var details: [String: JSONValue] = [
            "scope": .string(scope), "pid": JSONValue(Int(clamping: pid)), "process": .string(name),
            "cpu_share": .number(share), "wakeups": .array(top),
        ]
        if let label { details["serves"] = .string(label) }
        if !tabs.isEmpty {
            details["tabs"] = .array(tabs.map { ["tab": .string($0.tab), "title": .string($0.title)] })
        }
        let duration = Duration.nanoseconds(wall.saturatedInteger(Int64.self) ?? 0)
        let record = log.append(startUptimeNanos: end &- (wall.saturatedInteger(UInt64.self) ?? 0), duration: duration,
                                cpu: .nanoseconds((share * wall).saturatedInteger(Int64.self) ?? 0), addresses: addresses, kind: .busy, details: details)
        if configuration.logBusy {
            logger.error("busy \(scope, privacy: .public) \(name, privacy: .public) (\(tabs.count) tabs) at \(share * 100, format: .fixed(precision: 0))% CPU for \(wall / 1e9, format: .fixed(precision: 1)) s with no input, animation or output (hang \(record.sequence); see debug.hangs)")
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
        // SAFETY: thread_info writes at most `count` integer_t words, the size of `info` (a local live for the call),
        // and the count it wrote into `count`; the words are the info struct's own layout.
        let result = unsafe withUnsafeMutablePointer(to: &info) {
            unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) {
                unsafe thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(clamping: info.user_time.seconds) * 1_000_000_000 + UInt64(clamping: info.user_time.microseconds) * 1_000
        let system = UInt64(clamping: info.system_time.seconds) * 1_000_000_000 + UInt64(clamping: info.system_time.microseconds) * 1_000
        return user + system
    }
}
