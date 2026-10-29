import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextSignposts
public import CmuxNextTrace
public import CmuxNextWakeups
import Darwin
import os

/// The hang watch's monitor on the main-thread watchdog's thread (p09-observability 067):
/// it adds no thread and no timer. The watchdog thread's kqueue wait is bounded by the slot table's next
/// scan (``HangWatch/nextScanNanos``), and a scope that needs an earlier scan triggers the kqueue's user
/// event (``MainThreadWatchdog/attach(hangWatch:crashKeys:trace:)``). Chrome runs one `HangWatcher` thread per
/// process (base/threading/hang_watcher.cc); cmux's main-thread watchdog thread already waits on a kqueue, so
/// it takes the job.
///
/// Each overdue scope is reported once per tier, while it still runs, apart from the main-thread stalls:
/// - past its budget, a `jank` record in ``MainThreadWatchdog/threadJanks`` (`debug.hangs` `thread_janks`):
///   the registration's and the kernel's thread names and how far past its budget it is, with no stack (a
///   jank is common and costs no thread suspension; its own log, so janks never push hang dumps out);
/// - still open `HangWatch.hangAfterBudget` (2 s) later, a `hang` dump in ``MainThreadWatchdog/threadHangs``
///   (`debug.hangs` `thread_hangs`): the thread's stack (``ThreadStackSampler``) and the crash keys of the
///   moment. Like Chrome's `HangWatcher::RecordHang`, which names the hung threads in crash keys, the monitor
///   names the thread in the crash keys' hung threads (``CrashKeySlots/noteHung(_:)``) until its scope ends,
///   so a crash meanwhile says which threads were hung. Each hang dump also writes a `hang.thread_hung`
///   instant into the trace ring, and goes out as a ``ThreadHang``
///   (``MainThreadWatchdog/onThreadHang``: the crash report tagged `hang.thread` and the hang-report entry;
///   ``MainThreadWatchdog/onLastHang``: the local last-hang bundle) at most once per registration name per
///   `hangReportInterval`, as the main thread's hangs are, so a lane that hangs again and again sends one
///   report, not one per scope.
///
/// The scan marks a scope reported for its tier before its stack is sampled, and a stack sampled after the
/// scope ended is dropped (``HangWatch/isStillOpen(_:)``): Chrome's mark-then-capture
/// (`HangWatchDeadline::SetShouldBlockOnHang`) without its `BlockIfCaptureInProgress`, so a watched thread
/// never waits for the watchdog.
///
/// When the watchdog thread's wait overruns its timeout by more than ``driftToleranceNanos`` (100 ms), the
/// monitor blames nobody: the machine was too busy for its own thread, so the scopes open then may be late for
/// the same reason. Those scopes are cancelled in both tiers (``HangWatch/ignoreOpenScopes()``); a scope that
/// opens later is watched. Only the wait is timed, as Chrome's `HangWatcher::Wait` times only its `TimedWait`
/// against `kWaitDriftTolerance` (base/threading/hang_watcher.cc): the watchdog's own work between two waits,
/// such as a main-thread hang report, is not drift.
///
/// Each reported hang counts in `hang.thread_hung.<lane>` per active hour (``MainThreadFieldMetrics``).
struct HangMonitor {
    /// What ``MainThreadWatchdog/attach(hangWatch:crashKeys:trace:)`` connected.
    struct Source: Sendable {
        let watch: HangWatch
        let crashKeys: CrashKeySlots?
        /// The runtime whose ring gets each hang dump's `hang.thread_hung` instant; nil writes none.
        var trace: TraceRuntime?
        #if DEBUG
        /// Tests: told each hang dump on the watchdog thread, right after it is logged.
        var afterHangForTesting: (@Sendable (HangRecord) -> Void)?
        #endif
    }

    let watch: HangWatch
    /// Hang dumps (``HangRecord/Kind/hang``).
    let log: HangLog
    /// Janks (``HangRecord/Kind/jank``).
    let janks: HangLog
    let logger: Logger?
    let crashKeys: CrashKeySlots?
    /// Counts each reported hang per lane and active hour; nil counts nothing.
    let fieldMetrics: MainThreadFieldMetrics?
    let trace: TraceRuntime?
    /// Where each hang dump goes out (the watchdog's ``MainThreadWatchdog/onThreadHang`` and
    /// ``MainThreadWatchdog/onLastHang``), rate-limited by ``intervalNanos``.
    let deliver: @Sendable (ThreadHang) -> Void
    /// The least time between two deliveries for one registration name (the watchdog's `hangReportInterval`).
    let intervalNanos: UInt64
    #if DEBUG
    let afterHangForTesting: (@Sendable (HangRecord) -> Void)?
    #endif
    /// The reported scopes still named in ``crashKeys``' hung threads (at most its capacity).
    private var named: [HangWatch.Overdue] = []
    /// How many times the watchdog thread's wait overran its timeout by more than ``driftToleranceNanos``.
    private(set) var lateWakes = 0
    /// When each registration name's hang last went out (the slot table's clock): one entry per catalog name.
    private var delivered: [String: UInt64] = [:]

    /// How far a wait may overrun its timeout before the monitor blames nobody (Chrome's `kWaitDriftTolerance`).
    static let driftToleranceNanos: UInt64 = 100_000_000

    init(source: Source, log: HangLog, janks: HangLog, logger: Logger?, fieldMetrics: MainThreadFieldMetrics? = nil,
         intervalNanos: UInt64, deliver: @escaping @Sendable (ThreadHang) -> Void) {
        (self.watch, self.crashKeys, self.trace, self.log, self.janks, self.logger) =
            (source.watch, source.crashKeys, source.trace, log, janks, logger)
        self.fieldMetrics = fieldMetrics
        (self.intervalNanos, self.deliver) = (intervalNanos, deliver)
        #if DEBUG
        afterHangForTesting = source.afterHangForTesting
        #endif
        named.reserveCapacity(CrashKeySlots.hungThreadCapacity)
    }

    /// Scans when a scan is due and reports what it finds (watchdog thread only).
    ///
    /// - Parameter waitOverrunNanos: How far the watchdog thread's last wait ran past its timeout (0: it ended
    ///   in time, early, or had no timeout). Past ``driftToleranceNanos``, no scope open now is reported.
    /// - Returns: How long the watchdog thread may wait before the next scan; nil while the slot table
    ///   is parked (a scope wakes the thread through the kqueue).
    mutating func service(waitOverrunNanos: UInt64 = 0) -> UInt64? {
        clearEndedHangs()
        if waitOverrunNanos > Self.driftToleranceNanos { ignoreOpenScopes(overrunNanos: waitOverrunNanos) }
        guard let planned = watch.nextScanNanos else { return nil }
        let now = watch.nowNanos()
        guard planned <= now else { return planned - now }
        let result = watch.scan(nowNanos: now)
        for overdue in result.overdue { report(overdue, now: now) }
        guard let next = result.nextScanNanos else { return nil }
        let after = watch.nowNanos()
        return next > after ? next - after : 0
    }

    /// The watchdog thread woke `overrunNanos` past its wait's timeout: no scope open now is blamed, however long
    /// it runs.
    private mutating func ignoreOpenScopes(overrunNanos: UInt64) {
        lateWakes += 1
        let ignored = watch.ignoreOpenScopes()
        let late = Duration.nanoseconds(Int64(clamping: overrunNanos))
        logger?.notice("hang watch: the watchdog woke \(late.fractionalMilliseconds, format: .fixed(precision: 1)) ms late; \(ignored) open scopes are not reported")
    }

    /// Takes each named scope that ended off ``named``, and its thread off the crash keys' hung threads once no
    /// other named scope runs on that thread. A reported scope that closes asks the slot table for a scan now
    /// (`HangWatch` close), which wakes the watchdog thread even when the monitor was parked, so this runs at once.
    private mutating func clearEndedHangs() {
        guard let crashKeys, !named.isEmpty else { return }
        let watch = watch // the closure reads a local, not `self`, while `named` is being changed
        var ended: [UInt32] = []
        named.removeAll { overdue in
            guard !watch.isStillOpen(overdue) else { return false }
            ended.append(overdue.port)
            return true
        }
        for port in ended where !named.contains(where: { $0.port == port }) { crashKeys.clearHung(port: port) }
    }

    private mutating func report(_ overdue: HangWatch.Overdue, now: UInt64) {
        guard overdue.port != 0 else { return }
        let overrunNanos = now > overdue.deadlineNanos ? now - overdue.deadlineNanos : 0
        let overrun = Duration.nanoseconds(Int64(clamping: overrunNanos))
        var details: [String: JSONValue] = ["scope": .string(overdue.name),
                                            "thread_kind": .string(overdue.kind.map { "\($0)" } ?? "")]
        guard overdue.tier == .hang else {
            details["thread"] = .string(MachThreads.name(overdue.port))
            janks.append(startUptimeNanos: overdue.deadlineNanos, duration: overrun, addresses: [], kind: .jank, details: details)
            return
        }
        countHang(overdue)
        let addresses = ThreadStackSampler(thread: overdue.port).sample()
        // The scope ended while it was sampled: the stack belongs to later work.
        guard watch.isStillOpen(overdue) else { return }
        if let crashKeys, crashKeys.noteHung(CrashKeySlots.HungThread(port: overdue.port, kind: overdue.kind?.rawValue ?? 0)) {
            named.append(overdue)
        }
        let threadName = MachThreads.name(overdue.port)
        details["thread"] = .string(threadName)
        if let tags = crashKeys?.snapshot().tags, !tags.isEmpty { details["crash_keys"] = .object(tags.mapValues(JSONValue.string)) }
        let record = log.append(startUptimeNanos: overdue.deadlineNanos, duration: overrun, addresses: addresses, kind: .hang, details: details)
        logger?.error("hang: \(overdue.name, privacy: .public) on thread \(threadName, privacy: .public) past its budget by \(overrun.fractionalMilliseconds, format: .fixed(precision: 1)) ms (thread hang \(record.sequence), \(addresses.count) frames; see debug.hangs thread_hangs)")
        // arg0: the hung thread's id, the key of the ring's thread table (which names it); the record itself is the watchdog thread's.
        if let trace {
            let tid = MachThreads.info(overdue.port, THREAD_IDENTIFIER_INFO, thread_identifier_info_data_t())?.thread_id ?? 0
            trace.event(.hangThreadHung, arg0: tid, arg1: overrunNanos / 1_000_000)
        }
        if isDue(overdue.name, now: now) {
            deliver(ThreadHang(name: overdue.name, kind: overdue.kind, threadName: threadName, budgetEndNanos: overdue.deadlineNanos,
                               overrun: overrun, addresses: addresses))
        }
        #if DEBUG
        afterHangForTesting?(record)
        #endif
    }

    /// Counts a hang in its lane's `hang.thread_hung` (the watchdog counts the main thread's own hangs from its
    /// heartbeat, so a main-thread slot is not counted twice).
    private func countHang(_ overdue: HangWatch.Overdue) {
        guard let fieldMetrics, overdue.kind != .main else { return }
        fieldMetrics.threadHung(Self.lane(name: overdue.name, kind: overdue.kind), atNanos: overdue.deadlineNanos)
    }

    /// The `hang.thread_hung` lane of a registration: by the name its owner registers (`HangWatchedLane`,
    /// `BackgroundWork.hangScopeName`), else by its kind; `other` for a lane this table does not name yet.
    static func lane(name: String, kind: HangWatch.ThreadKind?) -> HistogramID.HangLane {
        switch name {
        case "daemon.line": return .daemonReader
        case "terminal.feed": return .terminalOutput
        case "lane.files", "lane.system", "lane.cpu", "lane.bulk-files": return .backgroundWork
        default: break
        }
        switch kind {
        case .main: return .main
        case .control: return .control
        default: return .other
        }
    }

    /// Whether `name`'s hang may go out at `now` (none did in the last ``intervalNanos``); notes it when it may.
    private mutating func isDue(_ name: String, now: UInt64) -> Bool {
        if let last = delivered[name], now < last &+ intervalNanos { return false }
        delivered[name] = now
        return true
    }
}

extension MainThreadWatchdog {
    /// Where a delivered thread hang goes: the reports' sink and the last-hang bundle's.
    struct ThreadHangSinks: Sendable {
        var report: (@Sendable (ThreadHang) -> Void)?
        var lastHang: (@Sendable (LastHangCause) -> Void)?
    }

    /// Receives each watched thread's hang dump (``ThreadHang``, ``attach(hangWatch:crashKeys:trace:)``) on the
    /// watchdog thread, at most once per registration name per `hangReportInterval`: the app sends it to crash
    /// reporting and hang reports. It must not wait for the main thread or the hung thread.
    ///
    /// Lock carve-out: as ``onHang``'s sink, `threadHangSinks` is set once at launch and read on the watchdog thread
    /// once per delivered thread hang; it is never held across a call.
    public var onThreadHang: (@Sendable (ThreadHang) -> Void)? {
        get { threadHangSinks.withLock { $0.report } }
        set { threadHangSinks.withLock { $0.report = newValue } }
    }

    /// Starts the local last-hang bundle (task p09-observability-125 sets it) for each thread hang that goes out,
    /// on the watchdog thread and apart from ``onThreadHang``: hang-report consent and crash reporting do not gate
    /// it. It must not wait for the main thread or the hung thread.
    public var onLastHang: (@Sendable (LastHangCause) -> Void)? {
        get { threadHangSinks.withLock { $0.lastHang } }
        set { threadHangSinks.withLock { $0.lastHang = newValue } }
    }

    /// Hands one rate-limited thread hang to both sinks, read once and called outside the lock.
    func deliverThreadHang(_ hang: ThreadHang) {
        let sinks = threadHangSinks.withLock { $0 }
        sinks.report?(hang)
        sinks.lastHang?(.threadHang(hang))
    }

    /// Watches `hangWatch`'s scopes on this watchdog's thread (the composition root passes
    /// `TraceRuntime.shared.hangWatch` and its ``CrashKeySlots``): each scope past its budget goes into
    /// ``threadJanks`` and, still open 2 s later, into ``threadHangs``, named in `crashKeys`' hung threads
    /// while it stays open, with a `hang.thread_hung` instant in `trace`'s ring and out through ``onThreadHang``
    /// and ``onLastHang``.
    /// The same `crashKeys` and `trace` say whether stall and hang records caught the main thread in the Chromium
    /// message pump (``inCEFPump(cefState:pumpKey:)``: `cef=true`, phase `cef_pump`).
    /// Once: a later call, or a slot table another monitor watches, is ignored. With no kqueue the watchdog
    /// thread does not run, so nothing is attached.
    public func attach(hangWatch: HangWatch, crashKeys: CrashKeySlots? = nil, trace: TraceRuntime? = nil) {
        attach(HangMonitor.Source(watch: hangWatch, crashKeys: crashKeys, trace: trace))
    }

    /// ``attach(hangWatch:crashKeys:trace:)`` with the whole source (tests add their hook).
    func attach(_ source: HangMonitor.Source) {
        guard alarm.isAvailable, source.watch.attachMonitor(wake: { [alarm] in alarm.wake() }) else { return }
        hangWatchSink.withLock { $0 = source }
        hangWatchAttached.store(true, ordering: .releasing)
        alarm.wake() // the thread picks it up now, not at its next wake
    }

    /// The monitor of the attached slot table, made on the watchdog thread once one is attached.
    func hangMonitor() -> HangMonitor? {
        guard hangWatchAttached.load(ordering: .acquiring), let source = hangWatchSink.withLock({ $0 }) else { return nil }
        return HangMonitor(source: source, log: threadHangs, janks: threadJanks, logger: configuration.logStalls ? logger : nil,
                           fieldMetrics: fieldMetrics, intervalNanos: hangIntervalNanos,
                           deliver: { [weak self] hang in self?.deliverThreadHang(hang) })
    }
}
