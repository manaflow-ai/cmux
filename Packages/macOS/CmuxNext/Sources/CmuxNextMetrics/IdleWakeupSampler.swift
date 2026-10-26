import Darwin

/// `idle.wakeups.{app_main, app_total, daemon}`: the app's and the local daemon's wakeups per idle minute, where idle
/// is the app inactive with no input from the person (plans/cmux-next/chrome-parity/p09-observability.md, task 059).
///
/// Chrome records `PerformanceMonitor.IdleWakeups` from `ProcessMetrics::GetIdleWakeupsPerSecond`
/// (base/process/process_metrics_apple.mm, `task_interrupt_wakeups`), sampled on the repeating timer of
/// chrome/browser/performance_monitor/process_monitor.cc. cmux reads the same kernel counter (`proc_pid_rusage`
/// `RUSAGE_INFO_V4`: `ri_interrupt_wkups`, with `ri_pkg_idle_wkups`) with no timer and no observer of its own: only in
/// the app delegate's resign and become-active callbacks, turns the activation wakes anyway, and at report triggers (a
/// decided quit), so measuring adds no wakeup to the idle it measures.
///
/// - A period opens when the app resigns active (or starts inactive) and closes when it becomes active again. A report
///   trigger records the period so far and opens the next one.
/// - A period with an input event records nothing and counts in ``periodsWithInput``: the person was using the app.
/// - A period under ``minimumPeriodNanos`` records nothing; at a report trigger it stays open.
/// - `app_main` counts the watchdog's main run-loop wakes (`debug.hangs` `main_wakes`), `app_total` the app's interrupt
///   wakeups and `daemon` the local daemon's: the counters scripts/cmux-next/bench_idle.py reads. A process whose pid
///   changed in the period (a daemon restart) records no sample for it.
/// - Package-idle wakeups, a subset of the interrupt wakeups, are in ``lastPeriod``; the catalog has no histogram for
///   them.
///
/// ```swift
/// let sampler = IdleWakeupSampler(sources: .live(mainRunLoopWakes: { watchdog.mainRunLoopWakes },
///                                                inputEvents: { activity.count(.input) },
///                                                daemonPID: { daemon.identity?.pid }))
/// sampler.appResignedActive()  // applicationDidResignActive
/// sampler.appBecameActive()    // applicationDidBecomeActive: records the period
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
        /// The person's input events so far.
        public var inputEvents: UInt64
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

        /// `count` over the period as a rate per minute, rounded down.
        public func perMinute(_ count: UInt64) -> Int64 {
            guard nanos > 0 else { return 0 }
            let scaled = count.multipliedFullWidth(by: 60_000_000_000)
            guard nanos > scaled.high else { return .max }  // the quotient would not fit 64 bits
            return Int64(clamping: nanos.dividingFullWidth(scaled).quotient)
        }
    }

    /// Where the sampler reads its counters (the tests' seam). Each is called only at a transition or a report trigger.
    public struct Sources {
        public var uptimeNanos: @MainActor () -> UInt64
        public var inputEvents: @MainActor () -> UInt64
        public var mainRunLoopWakes: @MainActor () -> UInt64?
        public var appWakeups: @MainActor () -> Wakeups?
        public var daemonWakeups: @MainActor () -> Wakeups?

        public init(uptimeNanos: @escaping @MainActor () -> UInt64, inputEvents: @escaping @MainActor () -> UInt64,
                    mainRunLoopWakes: @escaping @MainActor () -> UInt64?, appWakeups: @escaping @MainActor () -> Wakeups?,
                    daemonWakeups: @escaping @MainActor () -> Wakeups?) {
            self.uptimeNanos = uptimeNanos
            self.inputEvents = inputEvents
            self.mainRunLoopWakes = mainRunLoopWakes
            self.appWakeups = appWakeups
            self.daemonWakeups = daemonWakeups
        }

        /// This process's and the daemon's kernel counters (``IdleWakeupSampler/wakeups(of:)``), the uptime clock,
        /// and the app's main-wake and input counters.
        ///
        /// - Parameters:
        ///   - mainRunLoopWakes: The watchdog's main run-loop wakes.
        ///   - inputEvents: The person's input events (the app's `ExpectedActivity` input count).
        ///   - daemonPID: The local daemon's pid, nil before it connects.
        public static func live(mainRunLoopWakes: @escaping @MainActor () -> UInt64?, inputEvents: @escaping @MainActor () -> UInt64,
                                daemonPID: @escaping @MainActor () -> Int32?) -> Sources {
            let pid = getpid()
            return Sources(uptimeNanos: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }, inputEvents: inputEvents,
                           mainRunLoopWakes: mainRunLoopWakes, appWakeups: { IdleWakeupSampler.wakeups(of: pid) },
                           daemonWakeups: { daemonPID().flatMap { $0 > 0 ? IdleWakeupSampler.wakeups(of: $0) : nil } })
        }
    }

    /// The most recent period that recorded, nil before the first.
    public private(set) var lastPeriod: Period?
    /// Periods that ended with an input event in them and recorded nothing.
    public private(set) var periodsWithInput: UInt64 = 0
    private let sources: Sources
    private let metrics: Metrics
    /// The counters where the open period began; nil while the app is active.
    private var start: Counters?

    /// A sampler with no open period.
    ///
    /// - Parameters:
    ///   - sources: The counters (``Sources/live(mainRunLoopWakes:inputEvents:daemonPID:)`` in the app).
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

    private enum Outcome { case recorded, hadInput, tooShort }

    private func read() -> Counters {
        Counters(uptimeNanos: sources.uptimeNanos(), inputEvents: sources.inputEvents(), mainRunLoopWakes: sources.mainRunLoopWakes(),
                 app: sources.appWakeups(), daemon: sources.daemonWakeups())
    }

    /// Records the period from `start` to `end`, unless it had input or is under a minute.
    private func close(_ start: Counters, at end: Counters) -> Outcome {
        guard end.inputEvents == start.inputEvents else {
            periodsWithInput &+= 1
            return .hadInput
        }
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
