import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextSettings
public import CmuxNextTrace
public import CmuxNextWakeups
import Darwin
import os

/// The hang watch's monitor on the main-thread watchdog's thread (p02-threads-016, p09-observability 067):
/// it adds no thread and no timer. The watchdog thread's kqueue wait is bounded by the slot table's next
/// scan (``HangWatch/nextScanNanos``), and a scope that needs an earlier scan triggers the kqueue's user
/// event (``MainThreadWatchdog/attach(hangWatch:crashKeys:)``). Chrome runs one `HangWatcher` thread per
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
///   so a crash meanwhile says which threads were hung.
///
/// The scan marks a scope reported for its tier before its stack is sampled, and a stack sampled after the
/// scope ended is dropped (``HangWatch/isStillOpen(_:)``): Chrome's mark-then-capture
/// (`HangWatchDeadline::SetShouldBlockOnHang`) without its `BlockIfCaptureInProgress`, so a watched thread
/// never waits for the watchdog.
///
/// A monitor that wakes more than ``driftToleranceNanos`` (100 ms) after the time it asked for blames nobody:
/// the machine was too busy for its own thread, so the scopes open then may be late for the same reason. Their
/// latest budget becomes the ignore threshold, and no scope due by it is reported, in either tier (Chrome's
/// `kWaitDriftTolerance` and `deadline_ignore_threshold_`, base/threading/hang_watcher.cc `HangWatcher::Wait`).
///
/// Each reported hang counts in `hang.thread_hung.<lane>` per active hour (``MainThreadFieldMetrics``).
struct HangMonitor {
    /// What ``MainThreadWatchdog/attach(hangWatch:crashKeys:)`` connected.
    struct Source: Sendable {
        let watch: HangWatch
        let crashKeys: CrashKeySlots?
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
    #if DEBUG
    let afterHangForTesting: (@Sendable (HangRecord) -> Void)?
    #endif
    /// The reported scopes still named in ``crashKeys``' hung threads (at most its capacity).
    private var named: [HangWatch.Overdue] = []
    /// When the last ``service()`` asked to be called again (`CLOCK_UPTIME_RAW` nanoseconds); nil when it parked.
    private var expectedWakeNanos: UInt64?
    /// No scope due by this budget is reported: it was open when the monitor woke late.
    private(set) var ignoreThroughNanos: UInt64 = 0
    /// How many times the monitor woke more than ``driftToleranceNanos`` late.
    private(set) var lateWakes = 0

    /// How late the monitor may wake before it blames nobody (Chrome's `kWaitDriftTolerance`).
    static let driftToleranceNanos: UInt64 = 100_000_000

    init(source: Source, log: HangLog, janks: HangLog, logger: Logger?, fieldMetrics: MainThreadFieldMetrics? = nil) {
        (self.watch, self.crashKeys, self.log, self.janks, self.logger) = (source.watch, source.crashKeys, log, janks, logger)
        self.fieldMetrics = fieldMetrics
        #if DEBUG
        afterHangForTesting = source.afterHangForTesting
        #endif
        named.reserveCapacity(CrashKeySlots.hungThreadCapacity)
    }

    /// Scans when a scan is due and reports what it finds (watchdog thread only).
    ///
    /// - Returns: How long the watchdog thread may wait before the next scan; nil while the slot table
    ///   is parked (a scope wakes the thread through the kqueue).
    mutating func service() -> UInt64? {
        clearEndedHangs()
        let now = watch.nowNanos()
        let lateNanos = expectedWakeNanos.map { now > $0 ? now - $0 : 0 } ?? 0
        expectedWakeNanos = nil
        guard let planned = watch.nextScanNanos else { return nil }
        guard planned <= now else {
            expectedWakeNanos = planned
            return planned - now
        }
        let result = watch.scan(nowNanos: now)
        if lateNanos > Self.driftToleranceNanos { ignoreScopes(through: result.latestOpenDeadlineNanos, lateNanos: lateNanos) }
        for overdue in result.overdue where overdue.deadlineNanos > ignoreThroughNanos { report(overdue, now: now) }
        guard let next = result.nextScanNanos else { return nil }
        expectedWakeNanos = next
        let after = watch.nowNanos()
        return next > after ? next - after : 0
    }

    /// The monitor woke `lateNanos` after the time it asked for: no scope open now is blamed, however long it runs.
    private mutating func ignoreScopes(through latestOpen: UInt64, lateNanos: UInt64) {
        lateWakes += 1
        ignoreThroughNanos = max(ignoreThroughNanos, latestOpen)
        let late = Duration.nanoseconds(Int64(clamping: lateNanos))
        logger?.notice("hang watch: the monitor woke \(late.fractionalMilliseconds, format: .fixed(precision: 1)) ms late; the scopes open now are not reported")
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
        let overrun = Duration.nanoseconds(Int64(clamping: now > overdue.deadlineNanos ? now - overdue.deadlineNanos : 0))
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
        case "lane.files", "lane.system", "lane.cpu": return .backgroundWork
        default: break
        }
        switch kind {
        case .main: return .main
        case .control: return .control
        default: return .other
        }
    }
}

extension MainThreadWatchdog {
    /// Watches `hangWatch`'s scopes on this watchdog's thread (the composition root passes
    /// `TraceRuntime.shared.hangWatch` and its ``CrashKeySlots``): each scope past its budget goes into
    /// ``threadJanks`` and, still open 2 s later, into ``threadHangs``, named in `crashKeys`' hung threads
    /// while it stays open. The same `crashKeys` give stall and hang records the main thread's phase
    /// (``phaseLabel(cefState:)``). Once: a later call, or a slot table another monitor watches, is ignored.
    /// With no kqueue the watchdog thread does not run, so nothing is attached.
    public func attach(hangWatch: HangWatch, crashKeys: CrashKeySlots? = nil) {
        attach(HangMonitor.Source(watch: hangWatch, crashKeys: crashKeys))
    }

    /// ``attach(hangWatch:crashKeys:)`` with the whole source (tests add their hook).
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
                           fieldMetrics: fieldMetrics)
    }
}
