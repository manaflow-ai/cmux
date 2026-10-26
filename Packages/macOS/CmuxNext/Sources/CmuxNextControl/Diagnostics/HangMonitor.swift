import CmuxNextCompat
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
    #if DEBUG
    let afterHangForTesting: (@Sendable (HangRecord) -> Void)?
    #endif
    /// The reported scopes still named in ``crashKeys``' hung threads (at most its capacity).
    private var named: [HangWatch.Overdue] = []

    init(source: Source, log: HangLog, janks: HangLog, logger: Logger?) {
        (self.watch, self.crashKeys, self.log, self.janks, self.logger) = (source.watch, source.crashKeys, log, janks, logger)
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
        guard let planned = watch.nextScanNanos else { return nil }
        let now = watch.nowNanos()
        guard planned <= now else { return planned - now }
        let result = watch.scan(nowNanos: now)
        for overdue in result.overdue { report(overdue, now: now) }
        guard let next = result.nextScanNanos else { return nil }
        let after = watch.nowNanos()
        return next > after ? next - after : 0
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
            details["thread"] = .string(ThreadStackSampler.threadName(overdue.port))
            janks.append(startUptimeNanos: overdue.deadlineNanos, duration: overrun, addresses: [], kind: .jank, details: details)
            return
        }
        let addresses = ThreadStackSampler(thread: overdue.port).sample()
        // The scope ended while it was sampled: the stack belongs to later work.
        guard watch.isStillOpen(overdue) else { return }
        if let crashKeys, crashKeys.noteHung(CrashKeySlots.HungThread(port: overdue.port, kind: overdue.kind?.rawValue ?? 0)) {
            named.append(overdue)
        }
        let threadName = ThreadStackSampler.threadName(overdue.port)
        details["thread"] = .string(threadName)
        if let tags = crashKeys?.snapshot().tags, !tags.isEmpty { details["crash_keys"] = .object(tags.mapValues(JSONValue.string)) }
        let record = log.append(startUptimeNanos: overdue.deadlineNanos, duration: overrun, addresses: addresses, kind: .hang, details: details)
        logger?.error("hang: \(overdue.name, privacy: .public) on thread \(threadName, privacy: .public) past its budget by \(overrun.fractionalMilliseconds, format: .fixed(precision: 1)) ms (thread hang \(record.sequence), \(addresses.count) frames; see debug.hangs thread_hangs)")
        #if DEBUG
        afterHangForTesting?(record)
        #endif
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
        return HangMonitor(source: source, log: threadHangs, janks: threadJanks, logger: configuration.logStalls ? logger : nil)
    }
}
