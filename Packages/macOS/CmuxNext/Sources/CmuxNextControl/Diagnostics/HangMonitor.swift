import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import Darwin
import os

/// The hang watch's monitor on the main-thread watchdog's thread (p02-threads-016, p09-observability 067):
/// it adds no thread and no timer. The watchdog thread's kqueue wait is bounded by the slot table's next
/// scan (``HangWatch/nextScanNanos``), and a scope that needs an earlier scan triggers the kqueue's user
/// event (``MainThreadWatchdog/attach(hangWatch:)``). Chrome runs one `HangWatcher` thread per process
/// (base/threading/hang_watcher.cc); cmux's main-thread watchdog thread already waits on a kqueue, so it
/// takes the job.
///
/// Each overdue scope is reported once, while it still runs: the thread's stack (``ThreadStackSampler``),
/// the registration's and the kernel's thread names and how far past its deadline it is, into the
/// watchdog's ``MainThreadWatchdog/threadHangs`` log (`debug.hangs` `thread_hangs`, kind `hang`), apart from
/// the main-thread stalls.
struct HangMonitor {
    let watch: HangWatch
    let log: HangLog
    let logger: Logger?

    /// Scans when a scan is due and reports what it finds (watchdog thread only).
    ///
    /// - Returns: How long the watchdog thread may wait before the next scan; nil while the slot table
    ///   is parked (a scope wakes the thread through the kqueue).
    func service() -> UInt64? {
        guard let planned = watch.nextScanNanos else { return nil }
        let now = watch.nowNanos()
        guard planned <= now else { return planned - now }
        let result = watch.scan(nowNanos: now)
        for overdue in result.overdue { report(overdue, now: now) }
        guard let next = result.nextScanNanos else { return nil }
        let after = watch.nowNanos()
        return next > after ? next - after : 0
    }

    private func report(_ overdue: HangWatch.Overdue, now: UInt64) {
        guard overdue.port != 0 else { return }
        let addresses = ThreadStackSampler(thread: overdue.port).sample()
        // The scope ended while it was sampled: the stack belongs to later work.
        guard watch.isStillOpen(overdue) else { return }
        let overrun = Duration.nanoseconds(Int64(clamping: now > overdue.deadlineNanos ? now - overdue.deadlineNanos : 0))
        let threadName = ThreadStackSampler.threadName(overdue.port)
        let record = log.append(startUptimeNanos: overdue.deadlineNanos, duration: overrun, addresses: addresses, kind: .hang,
                                details: ["scope": .string(overdue.name), "thread": .string(threadName),
                                          "thread_kind": .string(overdue.kind.map { "\($0)" } ?? "")])
        logger?.error("hang: \(overdue.name, privacy: .public) on thread \(threadName, privacy: .public) past its deadline by \(overrun.fractionalMilliseconds, format: .fixed(precision: 1)) ms (thread hang \(record.sequence), \(addresses.count) frames; see debug.hangs thread_hangs)")
    }
}

extension MainThreadWatchdog {
    /// Watches `hangWatch`'s scopes on this watchdog's thread (the composition root passes
    /// `TraceRuntime.shared.hangWatch`); each scope past its deadline is reported into ``threadHangs``.
    /// Once: a later call, or a slot table another monitor watches, is ignored. With no kqueue the
    /// watchdog thread does not run, so nothing is attached.
    public func attach(hangWatch: HangWatch) {
        guard alarm.isAvailable, hangWatch.attachMonitor(wake: { [alarm] in alarm.wake() }) else { return }
        hangWatchSink.withLock { $0 = hangWatch }
        hangWatchAttached.store(true, ordering: .releasing)
        alarm.wake() // the thread picks it up now, not at its next wake
    }

    /// The monitor of the attached slot table, made on the watchdog thread once one is attached.
    func hangMonitor() -> HangMonitor? {
        guard hangWatchAttached.load(ordering: .acquiring), let watch = hangWatchSink.withLock({ $0 }) else { return nil }
        return HangMonitor(watch: watch, log: threadHangs, logger: configuration.logStalls ? logger : nil)
    }
}
