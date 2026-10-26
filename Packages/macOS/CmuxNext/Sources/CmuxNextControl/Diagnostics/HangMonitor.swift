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
/// Each overdue scope is reported once, while it still runs: the thread's stack (``ThreadStackSampler``),
/// the registration's and the kernel's thread names, how far past its deadline it is and the crash keys at
/// that moment, into the watchdog's ``MainThreadWatchdog/threadHangs`` log (`debug.hangs` `thread_hangs`, kind
/// `hang`), apart from the main-thread stalls. Like Chrome's `HangWatcher::RecordHang`, which names the hung
/// threads in crash keys, the monitor names each reported thread in the crash keys' hung threads
/// (``CrashKeySlots/noteHung(_:)``) until its scope ends, so a crash meanwhile says which threads were hung.
struct HangMonitor {
    /// What ``MainThreadWatchdog/attach(hangWatch:crashKeys:)`` connected.
    struct Source: Sendable {
        let watch: HangWatch
        let crashKeys: CrashKeySlots?
    }

    let watch: HangWatch
    let log: HangLog
    let logger: Logger?
    let crashKeys: CrashKeySlots?
    /// The reported scopes still named in ``crashKeys``' hung threads (at most its capacity).
    private var named: [HangWatch.Overdue] = []

    init(watch: HangWatch, log: HangLog, logger: Logger?, crashKeys: CrashKeySlots? = nil) {
        (self.watch, self.log, self.logger, self.crashKeys) = (watch, log, logger, crashKeys)
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
        let addresses = ThreadStackSampler(thread: overdue.port).sample()
        // The scope ended while it was sampled: the stack belongs to later work.
        guard watch.isStillOpen(overdue) else { return }
        if let crashKeys, crashKeys.noteHung(CrashKeySlots.HungThread(port: overdue.port, kind: overdue.kind?.rawValue ?? 0)) {
            named.append(overdue)
        }
        let overrun = Duration.nanoseconds(Int64(clamping: now > overdue.deadlineNanos ? now - overdue.deadlineNanos : 0))
        let threadName = ThreadStackSampler.threadName(overdue.port)
        var details: [String: JSONValue] = ["scope": .string(overdue.name), "thread": .string(threadName),
                                            "thread_kind": .string(overdue.kind.map { "\($0)" } ?? "")]
        if let tags = crashKeys?.snapshot().tags, !tags.isEmpty { details["crash_keys"] = .object(tags.mapValues(JSONValue.string)) }
        let record = log.append(startUptimeNanos: overdue.deadlineNanos, duration: overrun, addresses: addresses, kind: .hang, details: details)
        logger?.error("hang: \(overdue.name, privacy: .public) on thread \(threadName, privacy: .public) past its deadline by \(overrun.fractionalMilliseconds, format: .fixed(precision: 1)) ms (thread hang \(record.sequence), \(addresses.count) frames; see debug.hangs thread_hangs)")
    }
}

extension MainThreadWatchdog {
    /// Watches `hangWatch`'s scopes on this watchdog's thread (the composition root passes
    /// `TraceRuntime.shared.hangWatch`); each scope past its deadline is reported into ``threadHangs`` and, while
    /// it stays open, named in `crashKeys`' hung threads. Once: a later call, or a slot table another monitor
    /// watches, is ignored. With no kqueue the watchdog thread does not run, so nothing is attached.
    public func attach(hangWatch: HangWatch, crashKeys: CrashKeySlots? = nil) {
        guard alarm.isAvailable, hangWatch.attachMonitor(wake: { [alarm] in alarm.wake() }) else { return }
        hangWatchSink.withLock { $0 = HangMonitor.Source(watch: hangWatch, crashKeys: crashKeys) }
        hangWatchAttached.store(true, ordering: .releasing)
        alarm.wake() // the thread picks it up now, not at its next wake
    }

    /// The monitor of the attached slot table, made on the watchdog thread once one is attached.
    func hangMonitor() -> HangMonitor? {
        guard hangWatchAttached.load(ordering: .acquiring), let source = hangWatchSink.withLock({ $0 }) else { return nil }
        return HangMonitor(watch: source.watch, log: threadHangs, logger: configuration.logStalls ? logger : nil,
                           crashKeys: source.crashKeys)
    }
}
