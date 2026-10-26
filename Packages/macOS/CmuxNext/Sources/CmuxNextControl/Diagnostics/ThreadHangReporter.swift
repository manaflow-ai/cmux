public import Darwin
import CmuxNextCompat
import CmuxNextSignposts
public import CmuxNextTrace

/// Reports a registered hang-watch thread that stays in a scope past its deadline: one stack sample
/// of that thread (by the port its slot stored), one ``Hang`` to ``onHang`` (crash reporting and the
/// hang report), one `hang.thread_hung` instant in the trace ring and one ``onLastHangBundle``
/// request (the `last-hang/<n>` bundle of task 125).
///
/// This is Chrome's `HangWatcher::Monitor()` then `DoDumpWithoutCrashing()`
/// (base/threading/hang_watcher.cc). The monitor (task 067, on the main-thread watchdog's thread)
/// finds the overdue slots, marks them block-on-capture (`HangWatchDeadline::SetShouldBlockOnHang`)
/// and calls ``capture(_:)`` once per overdue slot at each check. As Chrome's
/// `deadline_ignore_threshold_`, one hang is captured once: the same scope (slot, generation and
/// deadline) never reports twice, and a thread name reports at most once per
/// ``Configuration/reportInterval``.
///
/// A `.main` slot gets its ring instant only: ``MainThreadWatchdog/onHang`` already reports the main
/// thread's hang, with every other thread's stack.
///
/// ```swift
/// let threadHangs = ThreadHangReporter(trace: runtime)
/// threadHangs.onHang = { hang in reporter.reportThreadHang(thread: hang.name, overdue: hang.overdue, addresses: hang.addresses) }
/// watchdog.attach(threadHangs: threadHangs)
/// watchdog.captureThreadHang(overdueSlot) // the monitor, on the watchdog thread
/// ```
public final class ThreadHangReporter: Sendable {
    /// How often one thread may report, and how deep its stack is.
    public struct Configuration: Sendable {
        /// At most one report per thread name in this interval (default 5 min, as the main thread's
        /// ``MainThreadWatchdog/Configuration/hangReportInterval``).
        public var reportInterval: Duration
        /// The most frames one sample keeps.
        public var maxFrames: Int

        /// A configuration.
        public init(reportInterval: Duration = .seconds(300), maxFrames: Int = 64) {
            self.reportInterval = reportInterval
            self.maxFrames = maxFrames
        }
    }

    /// One slot whose open scope is past its deadline, as the monitor reads it from the slot table.
    public struct Overdue: Sendable {
        /// The slot.
        public var registration: HangWatch.Registration
        /// What the thread runs.
        public var kind: HangWatch.ThreadKind
        /// The thread's or lane's catalog name.
        public var name: StaticString
        /// The name's id in the trace ring (the instant's arg0).
        public var nameID: UInt64
        /// The port of the thread that runs the scope (a lane job's own `mach_thread_self()`).
        public var port: thread_act_t
        /// The scope's deadline, `CLOCK_UPTIME_RAW` nanoseconds: it tells this scope from the next.
        public var deadlineNanos: UInt64

        /// An overdue slot.
        public init(registration: HangWatch.Registration, kind: HangWatch.ThreadKind, name: StaticString,
                    nameID: UInt64, port: thread_act_t, deadlineNanos: UInt64) {
            self.registration = registration
            self.kind = kind
            self.name = name
            self.nameID = nameID
            self.port = port
            self.deadlineNanos = deadlineNanos
        }
    }

    /// One reported thread hang.
    public struct Hang: Sendable, Equatable {
        /// The thread's or lane's catalog name (the Sentry tag `hang.thread`).
        public var name: String
        /// What the thread runs.
        public var kind: HangWatch.ThreadKind
        /// How far past its deadline the thread was when it was sampled.
        public var overdue: Duration
        /// Return addresses, innermost first.
        public var addresses: [UInt]
    }

    public let configuration: Configuration
    /// Receives each reported hang on the watchdog thread; it must not wait for the main thread.
    public var onHang: (@Sendable (Hang) -> Void)? {
        get { hangSink.withLock { $0 } }
        set { hangSink.withLock { $0 = newValue } }
    }
    /// Receives each reported hang after ``onHang``, on the watchdog thread: task 125 copies every
    /// process's black-box tail to `last-hang/<n>` (on BackgroundWork `.files`, never here).
    public var onLastHangBundle: (@Sendable (Hang) -> Void)? {
        get { bundleSink.withLock { $0 } }
        set { bundleSink.withLock { $0 = newValue } }
    }
    // Lock carve-out (these three): set once at wiring, then read only on the watchdog thread, so
    // never contended and never taken on main; as MainThreadWatchdog's sinks.
    private let hangSink = Mutex<(@Sendable (Hang) -> Void)?>(nil)
    private let bundleSink = Mutex<(@Sendable (Hang) -> Void)?>(nil)
    private let state = Mutex(State())
    private let trace: TraceRuntime
    /// `CLOCK_UPTIME_RAW` nanoseconds; tests move it by hand.
    private let uptime: @Sendable () -> UInt64
    private let intervalNanos: UInt64

    /// A reporter that writes its ring instants to `trace` (the composition root takes the process's
    /// runtime; tests pass their own).
    public convenience init(configuration: Configuration = Configuration(), trace: TraceRuntime = .shared) {
        self.init(configuration: configuration, trace: trace, uptime: { MainThreadWatchdog.now() })
    }

    init(configuration: Configuration, trace: TraceRuntime, uptime: @escaping @Sendable () -> UInt64) {
        self.configuration = configuration
        self.trace = trace
        self.uptime = uptime
        let (seconds, attoseconds) = configuration.reportInterval.components
        intervalNanos = UInt64(clamping: max(seconds, 0)).saturatingMultiplication(1_000_000_000)
            &+ UInt64(clamping: max(attoseconds, 0) / 1_000_000_000)
    }

    /// Captures one overdue slot: the first call for its scope records the ring instant, then, for a
    /// thread other than main whose name has not reported within the interval, samples the thread and
    /// reports it. Watchdog thread only (the monitor's one caller).
    ///
    /// - Parameter overdue: The slot past its deadline.
    /// - Returns: Whether a hang was reported (false: the scope was seen already, the slot is the main
    ///   thread, its name reported within the interval, or the thread could not be sampled).
    @discardableResult
    public func capture(_ overdue: Overdue) -> Bool {
        let fresh = state.withLock { $0.beginEpisode(overdue) }
        guard fresh else { return false }
        let now = uptime()
        let name = String(describing: overdue.name)
        let overdueNanos = now > overdue.deadlineNanos ? now - overdue.deadlineNanos : 0
        trace.event(.hangThreadHung, arg0: overdue.nameID, arg1: overdueNanos / 1_000_000)
        guard overdue.kind != .main, state.withLock({ $0.mayReport(name, nowNanos: now, intervalNanos: intervalNanos) }) else {
            return false
        }
        let addresses = ThreadStackSampler.sampleRegistered(port: overdue.port, maxFrames: configuration.maxFrames)
        guard !addresses.isEmpty else { return false }
        state.withLock { $0.lastReportNanos[name] = now }
        let hang = Hang(name: name, kind: overdue.kind, overdue: .nanoseconds(Int64(clamping: overdueNanos)), addresses: addresses)
        hangSink.withLock { $0 }?(hang)
        bundleSink.withLock { $0 }?(hang)
        return true
    }

    /// What has been captured: the scope each slot last reported, and when each name last reported.
    /// Both are bounded by the slot table and the name catalog.
    private struct State {
        var episodes: [UInt32: (generation: UInt32, deadlineNanos: UInt64)] = [:]
        var lastReportNanos: [String: UInt64] = [:]

        /// Whether `overdue` is a scope not seen before; remembers it.
        mutating func beginEpisode(_ overdue: Overdue) -> Bool {
            let key = overdue.registration.slot
            if let seen = episodes[key], seen.generation == overdue.registration.generation,
               seen.deadlineNanos == overdue.deadlineNanos {
                return false
            }
            episodes[key] = (overdue.registration.generation, overdue.deadlineNanos)
            return true
        }

        func mayReport(_ name: String, nowNanos: UInt64, intervalNanos: UInt64) -> Bool {
            guard let last = lastReportNanos[name] else { return true }
            return nowNanos >= last && nowNanos - last >= intervalNanos
        }
    }
}
