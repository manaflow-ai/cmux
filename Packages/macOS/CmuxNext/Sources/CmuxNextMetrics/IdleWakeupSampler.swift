import Darwin

/// `idle.wakeups.{app_main, app_total, daemon}`: the app's and the local daemon's wakeups per idle minute, where idle
/// is the app inactive with no input from the person (plans/cmux-next/chrome-parity/p09-observability.md, task 059).
///
/// Chrome records `PerformanceMonitor.IdleWakeups` from `ProcessMetrics::GetIdleWakeupsPerSecond`
/// (base/process/process_metrics_apple.mm, `task_interrupt_wakeups`), sampled on the repeating timer of
/// chrome/browser/performance_monitor/process_monitor.cc. cmux reads the same kernel counter (`proc_pid_rusage`
/// `RUSAGE_INFO_V4`: `ri_interrupt_wkups`, with `ri_pkg_idle_wkups`) with no timer and no observer of its own: only at
/// the app's resign and become-active notices (the app's one `AppEvents` fan-out), on the person's input turns (the
/// app's existing input-tap subscription), and at report triggers (a decided quit). Each of those wakes the app anyway,
/// so measuring adds no wakeup to the idle it measures.
///
/// - A period opens when the app resigns active (or starts inactive) and closes when it becomes active again. A report
///   trigger records the period so far and opens the next one.
/// - An input event from the person while the app is inactive (a pointer over a cmux window on the way back) ends the
///   period at that event: the idle before it records, and the next period opens at it. Such periods count in
///   ``periodsEndedByInput``.
/// - A period under ``minimumPeriodNanos`` records nothing; at a report trigger it stays open.
/// - `app_main` counts the watchdog's main run-loop wakes (`debug.hangs` `main_wakes`), `app_total` the app's interrupt
///   wakeups and `daemon` the local daemon's: the counters scripts/cmux-next/bench_idle.py reads. A process whose pid
///   changed in the period (a daemon restart) records no sample for it.
/// - Package-idle wakeups, a subset of the interrupt wakeups, are in ``lastPeriod``; the catalog has no histogram for
///   them.
///
/// ```swift
/// let sampler = IdleWakeupSampler(sources: .live(mainRunLoopWakes: { watchdog.mainRunLoopWakes },
///                                                daemonPID: { daemon.identity?.pid }))
/// sampler.appResignedActive()  // NSApplication.didResignActiveNotification
/// sampler.inputArrived()       // the person's input event: the idle before it records
/// sampler.appBecameActive()    // NSApplication.didBecomeActiveNotification: records the period
/// ```
@MainActor
public final class IdleWakeupSampler {
    /// The shortest period that records: one idle minute.
    public static let minimumPeriodNanos: UInt64 = 60 * 1_000_000_000

    /// One process's wakeup counters (cumulative since it started), or a period's change in them.
    public struct Wakeups: Sendable, Equatable {
        /// The process.
        public var pid: Int32
        /// Interrupt wakeups (`ri_interrupt_wkups`): the counter Chrome reports as idle wakeups.
        public var interrupt: UInt64
        /// Wakeups out of package idle (`ri_pkg_idle_wkups`), a subset of ``interrupt``.
        public var packageIdle: UInt64

        public init(pid: Int32, interrupt: UInt64, packageIdle: UInt64) {
            self.pid = pid
            self.interrupt = interrupt
            self.packageIdle = packageIdle
        }

        /// The change since `start`; nil when `start` was another process or a counter went back.
        func since(_ start: Wakeups) -> Wakeups? {
            guard pid == start.pid, interrupt >= start.interrupt, packageIdle >= start.packageIdle else { return nil }
            return Wakeups(pid: pid, interrupt: interrupt - start.interrupt, packageIdle: packageIdle - start.packageIdle)
        }
    }

    /// The counters at one transition.
    public struct Counters: Sendable, Equatable {
        /// `CLOCK_UPTIME_RAW` in ns: it stops while the Mac sleeps, as the wakeup counters do.
        public var uptimeNanos: UInt64
        /// The main run loop's wakes so far; nil without a running watchdog.
        public var mainRunLoopWakes: UInt64?
        /// The app's counters; nil when the read failed.
        public var app: Wakeups?
        /// The local daemon's counters; nil without a daemon or when the read failed.
        public var daemon: Wakeups?
    }

    /// One recorded idle period: its length and what each counter added in it.
    public struct Period: Sendable, Equatable {
        /// The period's length in ns of uptime.
        public var nanos: UInt64
        /// Main run-loop wakes in the period; nil when either end had no count.
        public var mainRunLoopWakes: UInt64?
        /// The app's wakeups in the period.
        public var app: Wakeups?
        /// The daemon's wakeups in the period.
        public var daemon: Wakeups?

        public init(nanos: UInt64, mainRunLoopWakes: UInt64?, app: Wakeups?, daemon: Wakeups?) {
            self.nanos = nanos
            self.mainRunLoopWakes = mainRunLoopWakes
            self.app = app
            self.daemon = daemon
        }

        /// `count` over the period as a rate per minute, rounded down.
        public func perMinute(_ count: UInt64) -> Int64 {
            guard nanos > 0 else { return 0 }
            let scaled = count.multipliedFullWidth(by: 60_000_000_000)
            guard nanos > scaled.high else { return .max }  // the quotient would not fit 64 bits
            return Int64(clamping: nanos.dividingFullWidth(scaled).quotient)
        }
    }

    /// Where the sampler reads its counters (the tests' seam). Each is called only at a transition, an input while inactive or
    /// a report trigger.
    public struct Sources {
        public var uptimeNanos: @MainActor () -> UInt64
        public var mainRunLoopWakes: @MainActor () -> UInt64?
        public var appWakeups: @MainActor () -> Wakeups?
        public var daemonWakeups: @MainActor () -> Wakeups?

        public init(uptimeNanos: @escaping @MainActor () -> UInt64, mainRunLoopWakes: @escaping @MainActor () -> UInt64?,
                    appWakeups: @escaping @MainActor () -> Wakeups?, daemonWakeups: @escaping @MainActor () -> Wakeups?) {
            self.uptimeNanos = uptimeNanos
            self.mainRunLoopWakes = mainRunLoopWakes
            self.appWakeups = appWakeups
            self.daemonWakeups = daemonWakeups
        }

        /// This process's and the daemon's kernel counters (``IdleWakeupSampler/wakeups(of:)``), the uptime clock,
        /// and the app's main-wake counter.
        ///
        /// - Parameters:
        ///   - mainRunLoopWakes: The watchdog's main run-loop wakes.
        ///   - daemonPID: The local daemon's pid, nil before it connects.
        public static func live(mainRunLoopWakes: @escaping @MainActor () -> UInt64?,
                                daemonPID: @escaping @MainActor () -> Int32?) -> Sources {
            let pid = getpid()
            return Sources(uptimeNanos: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                           mainRunLoopWakes: mainRunLoopWakes, appWakeups: { IdleWakeupSampler.wakeups(of: pid) },
                           daemonWakeups: { daemonPID().flatMap { $0 > 0 ? IdleWakeupSampler.wakeups(of: $0) : nil } })
        }
    }

    /// The most recent period that recorded, nil before the first.
    public private(set) var lastPeriod: Period?
    /// Periods that an input event from the person ended and that recorded.
    public private(set) var periodsEndedByInput: UInt64 = 0
    private let sources: Sources
    private let metrics: Metrics
    /// The counters where the open period began; nil while the app is active.
    private var start: Counters?

    /// A sampler with no open period.
    ///
    /// - Parameters:
    ///   - sources: The counters (``Sources/live(mainRunLoopWakes:daemonPID:)`` in the app).
    ///   - metrics: Where the samples go (the app runtime's metrics file by default; tests pass their own).
    public init(sources: Sources, metrics: Metrics = Metrics()) {
        self.sources = sources
        self.metrics = metrics
    }

    /// Whether a period is open (the app is inactive).
    public var isMeasuring: Bool { start != nil }

    /// The app resigned active (or started inactive): a period opens. One already open stays.
    public func appResignedActive() {
        guard start == nil else { return }
        start = read()
    }

    /// The app became active: the open period ends and records.
    public func appBecameActive() {
        guard let start else { return }
        self.start = nil
        _ = close(start, at: read())
    }

    // perf-hot: 5us main-turn (every input event the input tap hears; two proc_pid_rusage reads only while inactive)
    /// An input event from the person: the open period ends at it, recording the idle before it if that reached
    /// ``minimumPeriodNanos``, and the next one opens at it. While the app is active it does nothing.
    public func inputArrived() {
        guard let start else { return }
        let now = read()
        if close(start, at: now) == .recorded { periodsEndedByInput &+= 1 }
        self.start = now
    }

    /// A report is about to read the histograms (a decided quit): the open period records what it has and the next
    /// one starts now. A period under ``minimumPeriodNanos`` stays open.
    public func reportTriggered() {
        guard let start else { return }
        let now = read()
        if close(start, at: now) != .tooShort { self.start = now }
    }

    /// Reads `pid`'s wakeup counters (`proc_pid_rusage`, `RUSAGE_INFO_V4`): one system call that copies the kernel's
    /// counters, as `ProcessUsage` reads them for `debug.energy`; nil when the process is gone or not ours.
    public nonisolated static func wakeups(of pid: Int32) -> Wakeups? {
        var info = rusage_info_v4()
        // SAFETY: `info` is a local, live for the call; with RUSAGE_INFO_V4 the kernel writes one rusage_info_v4
        // through the pointer, the rebound pointer's own storage.
        let status = unsafe withUnsafeMutablePointer(to: &info) { pointer in
            unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { unsafe proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return Wakeups(pid: pid, interrupt: info.ri_interrupt_wkups, packageIdle: info.ri_pkg_idle_wkups)
    }

    private enum Outcome { case recorded, tooShort }

    private func read() -> Counters {
        Counters(uptimeNanos: sources.uptimeNanos(), mainRunLoopWakes: sources.mainRunLoopWakes(), app: sources.appWakeups(),
                 daemon: sources.daemonWakeups())
    }

    /// Records the period from `start` to `end`, unless it is under a minute.
    private func close(_ start: Counters, at end: Counters) -> Outcome {
        guard end.uptimeNanos >= start.uptimeNanos, end.uptimeNanos - start.uptimeNanos >= Self.minimumPeriodNanos else {
            return .tooShort
        }
        var mainWakes: UInt64?
        if let first = start.mainRunLoopWakes, let last = end.mainRunLoopWakes, last >= first { mainWakes = last - first }
        let period = Period(nanos: end.uptimeNanos - start.uptimeNanos, mainRunLoopWakes: mainWakes,
                            app: Self.change(start.app, end.app), daemon: Self.change(start.daemon, end.daemon))
        if let wakes = period.mainRunLoopWakes { metrics.record(.idleWakeups(.appMain), period.perMinute(wakes)) }
        if let app = period.app { metrics.record(.idleWakeups(.appTotal), period.perMinute(app.interrupt)) }
        if let daemon = period.daemon { metrics.record(.idleWakeups(.daemon), period.perMinute(daemon.interrupt)) }
        lastPeriod = period
        return .recorded
    }

    private static func change(_ start: Wakeups?, _ end: Wakeups?) -> Wakeups? {
        guard let start, let end else { return nil }
        return end.since(start)
    }
}
