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
/// `subtle::DelayPolicy::kFlexibleNoSooner`, base/task/delay_policy.h). An end
/// that rode another owner's wake records no ledger wake of its own. Shares
/// are judged over the real elapsed time from the window's start to its close.
/// The close runs in the fire, on the main thread; only a busy window's
/// main-thread stack sample goes to a pool thread, since a thread cannot sample
/// itself. A new window opens at once if the app woke during the window, also
/// after its nominal end, the fire's own turn not counted. An idle app
/// therefore costs nothing, and a steadily busy app one check per 10-20 s. A
/// spin on a background thread that never wakes the main thread is seen only
/// in the window after the last main-thread wake.
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

    public let configuration: Configuration
    private let log: HangLog
    private let ledger: WakeupLedger
    private let activity: ExpectedActivity
    private let helpers: Mutex<HelperSource>
    private let mainThread: Mutex<thread_act_t?> = Mutex(nil)
    private let sampler: Mutex<ThreadStackSampler?> = Mutex(nil)
    private let measuring = Atomic<Bool>(false)
    private let awakeDuringWindow = Atomic<Bool>(false)
    /// Main wakes after the open window's nominal end, while its end has not run yet.
    private let lateWakes = Atomic<Int>(0)
    /// The open window's nominal end (uptime ns), which splits ``awakeDuringWindow`` from ``lateWakes``.
    private let windowEnd = Atomic<UInt64>(0)
    /// Uptime ns, the clock of the window and of the wake queue's deadlines.
    private let uptime: @Sendable () -> UInt64
    /// Takes a busy window's main-thread stack sample off the main thread (``poolThread``; tests run it inline).
    private let offMain: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// The end runs on the main thread in the wake queue's fire; without a queue it sleeps on a pool thread.
    private let endsOnMain: Bool
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
    ///     sleeps the end on `clock` and runs it on a pool thread.
    public convenience init(configuration: Configuration = Configuration(), log: HangLog, ledger: WakeupLedger = .shared,
                            activity: ExpectedActivity = .shared, clock: any Clock<Duration> = ContinuousClock(),
                            wakeUps: MainWakeUpQueue? = nil) {
        self.init(configuration: configuration, log: log, ledger: ledger, activity: activity, clock: clock, wakeUps: wakeUps,
                  uptime: WakeupLedger.systemUptime, offMain: Self.poolThread)
    }

    /// The seam initializer: `uptime` must be the clock of `wakeUps` (tests pass the queue's fake uptime) and
    /// `offMain` takes a busy window's stack sample (tests run it inline).
    init(configuration: Configuration, log: HangLog, ledger: WakeupLedger, activity: ExpectedActivity,
         clock: any Clock<Duration>, wakeUps: MainWakeUpQueue?, uptime: @escaping @Sendable () -> UInt64,
         offMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.configuration = configuration
        self.log = log
        self.ledger = ledger
        self.activity = activity
        self.uptime = uptime
        self.offMain = offMain
        self.endsOnMain = wakeUps != nil
        self.helpers = Mutex(HelperSource(list: { [] }, tabs: nil))
        // timer-class-allow: the window end has its class: `.flexibleNoSooner` with 10 s leeway on the main
        // thread's MainWakeUpQueue (wakes only when alone), else off main on `clock` with no queue to join
        self.timer = DemandTimer(owner: Self.windowOwner, policy: .flexibleNoSooner, clock: clock, ledger: ledger,
                                 energy: wakeUps?.energy, wakeUps: wakeUps, queueLedgerReason: .deadlineWhenAlone)
    }

    /// The ledger owner of each window end.
    static let windowOwner = "BusyWatchdog.window"

    /// Runs `work` on a pool thread: a `Task` made in a nonisolated context does not run on the main actor.
    static let poolThread: @Sendable (@escaping @Sendable () -> Void) -> Void = { work in _ = Task { work() } }

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
    /// serves. Called when a window closes with a busy tab renderer, on the main thread in the
    /// wake queue's fire: it returns a published snapshot (``TabRendererDirectory/snapshot()``) and never waits.
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

    /// The main run loop woke. Cheap: an uptime read and two atomics, or
    /// opening a window when none is open.
    public func noteAwake() {
        if measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            openWindow()
            return
        }
        if uptime() < windowEnd.load(ordering: .acquiring) {
            awakeDuringWindow.store(true, ordering: .relaxed)
        } else {
            lateWakes.add(1, ordering: .relaxed)
        }
    }

    private func openWindow() {
        awakeDuringWindow.store(false, ordering: .relaxed)
        lateWakes.store(0, ordering: .relaxed)
        let helperList = helperSource()()
        var sampled: [pid_t: (helper: Helper, usage: ProcessUsage)] = [:]
        for helper in helperList {
            if let usage = ProcessUsage.sample(helper.pid) { sampled[helper.pid] = (helper: helper, usage: usage) }
        }
        let startNanos = uptime()
        let start = Window(process: ProcessUsage.sample(getpid()), mainCPUNanos: mainCPUNanos(), activity: activity.total,
                           helpers: sampled, startNanos: startNanos)
        window.withLock { $0 = start }
        let windowNanos = UInt64(clamping: configuration.window.wholeMilliseconds).saturatingMultiplication(1_000_000)
        windowEnd.store(startNanos.saturatingAddition(windowNanos), ordering: .releasing)
        if endsOnMain {
            timer.scheduleOnMain(after: configuration.window, tolerance: configuration.windowLeeway) { [weak self] in
                self?.closeWindow(onMain: true)
            }
        } else {
            timer.schedule(after: configuration.window, tolerance: configuration.windowLeeway) { [weak self] in
                self?.closeWindow(onMain: false)
            }
        }
    }

    /// The window's end. `onMain`: it runs in a main-thread turn (the wake queue's fire), whose own wake is one
    /// of ``lateWakes`` and does not keep the watch going.
    private func closeWindow(onMain: Bool) {
        guard let start = window.withLock({ window in defer { window = nil }; return window }) else { return }
        // Read first, so a wake the close itself causes does not keep the watch going. The shares use the real
        // elapsed time, up to window + leeway.
        let stayAwake = awakeDuringWindow.load(ordering: .relaxed) || lateWakes.load(ordering: .relaxed) > (onMain ? 1 : 0)
        let now = uptime()
        let wall = Double(max(now &- start.startNanos, 1))
        let quiet = activity.total == start.activity
        if quiet {
            let mainShare = Double(mainCPUNanos() &- start.mainCPUNanos) / wall
            let process = ProcessUsage.sample(getpid())
            let processShare = process.flatMap { end in start.process.map { end.cpuShare(since: $0) } } ?? 0
            if mainShare > configuration.mainThreadThreshold || processShare > configuration.processThreshold {
                let scope = mainShare > configuration.mainThreadThreshold ? "main-thread" : "process"
                let name = process?.name ?? "app", share = max(mainShare, processShare)
                let sampleAndRecord: @Sendable () -> Void = { [self] in
                    let addresses = sampler.withLock { $0?.sample() } ?? []
                    record(scope: scope, pid: getpid(), name: name, label: nil, share: share, wall: wall, end: now,
                           addresses: addresses)
                }
                if onMain { offMain(sampleAndRecord) } else { sampleAndRecord() }
            }
            var busy: [(helper: Helper, name: String, share: Double)] = []
            for (pid, entry) in start.helpers {
                guard let usage = ProcessUsage.sample(pid) else { continue }
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
            openWindow()
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
