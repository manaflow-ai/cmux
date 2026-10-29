import CmuxNextCompat
public import CoreFoundation
import Darwin

/// The main process's idle interrupt wakeups per second over this launch, as a histogram with
/// fixed buckets (`debug.energy`'s `idle`).
///
/// Chrome samples the same counter (`ProcessMetrics::GetIdleWakeupsPerSecond` in
/// `base/process/process_metrics_apple.mm` reads `ri_interrupt_wkups`) from the repeating timer of
/// `chrome/browser/performance_monitor/process_monitor.cc` and records it into the
/// `PerformanceMonitor.IdleWakeups` histogram
/// (`chrome/browser/performance_monitor/process_metrics_recorder_util.cc`). cmux has no timer for
/// it: every step happens at a main run loop wake that other work starts, so an idle app wakes no
/// more often to measure itself.
///
/// Main process only: the helpers' counters are in `debug.energy`'s `processes`, the same
/// ``ProcessUsage/interruptWakeups`` counter.
///
/// The app is idle once ``idleAfterNanos`` pass with no input (and after launch): a window opens at
/// the first wake after that and is recorded at the first wake ``windowNanos`` later. Input in a
/// window drops it and starts the wait again at the first wake that sees the input, so no sample
/// holds an input or the work it started (animation, scroll momentum, reflow, fetches).
public struct IdleEnergyStats: Sendable, Equatable {
    /// No input for this long and the app is idle.
    public static let idleAfterNanos: UInt64 = 60 * 1_000_000_000
    /// The shortest window: a sample covers at least one idle minute.
    public static let windowNanos: UInt64 = 60 * 1_000_000_000

    /// The upper bounds (inclusive, wakeups/s) of every bucket but the last; the last bucket holds
    /// every rate above 50 ("50+"). 0.2/s falls in the 0.25 bucket.
    public static let upperBounds: [Double] = [0, 0.1, 0.25, 0.5, 1, 2, 5, 10, 50]

    /// Samples per bucket: `upperBounds.count + 1` entries, the overflow bucket last.
    public private(set) var counts = [UInt64](repeating: 0, count: IdleEnergyStats.upperBounds.count + 1)
    /// Open windows input dropped (input while the app is not yet idle drops none).
    public private(set) var windowsWithInput: UInt64 = 0
    /// The highest rate recorded (the overflow bucket's percentile value).
    public private(set) var maxRate: Double = 0
    /// The last rate recorded, nil before the first sample.
    public private(set) var lastRate: Double?
    private var phase: Phase?

    /// Where the histogram is between wakes; nil before the first wake.
    private enum Phase: Sendable, Equatable {
        /// Waiting for ``IdleEnergyStats/idleAfterNanos`` with no input from `since`, after `inputs` input events.
        case settling(since: UInt64, inputs: UInt64)
        /// A window open since `since` with `wakeups` interrupt wakeups then, after `inputs` input events.
        case measuring(since: UInt64, wakeups: UInt64, inputs: UInt64)
    }

    /// An empty histogram, before the first wake.
    public init() {}

    /// Samples recorded this launch.
    public var sampleCount: UInt64 { counts.reduce(0, &+) }

    /// One main run loop wake at `uptimeNanos` (`CLOCK_UPTIME_RAW`, which stops while the Mac sleeps
    /// as the counter does), after `inputEvents` input events. `interruptWakeups` reads the main
    /// process's counter; it is called only when a window opens or closes, and nil skips this wake.
    /// Returns the rate recorded at this wake, if any.
    @discardableResult
    public mutating func noteWake(at uptimeNanos: UInt64, inputEvents: UInt64, interruptWakeups: () -> UInt64?) -> Double? {
        switch phase {
        case nil:
            phase = .settling(since: uptimeNanos, inputs: inputEvents)
            return nil
        case let .settling(since, inputs):
            guard inputEvents == inputs else {
                phase = .settling(since: uptimeNanos, inputs: inputEvents)
                return nil
            }
            guard Self.elapsed(uptimeNanos, since: since, atLeast: Self.idleAfterNanos), let wakeups = interruptWakeups() else { return nil }
            phase = .measuring(since: uptimeNanos, wakeups: wakeups, inputs: inputEvents)
            return nil
        case let .measuring(since, startWakeups, inputs):
            guard inputEvents == inputs else {
                windowsWithInput &+= 1
                phase = .settling(since: uptimeNanos, inputs: inputEvents)
                return nil
            }
            guard Self.elapsed(uptimeNanos, since: since, atLeast: Self.windowNanos), let wakeups = interruptWakeups() else { return nil }
            phase = .measuring(since: uptimeNanos, wakeups: wakeups, inputs: inputEvents)
            guard wakeups >= startWakeups else { return nil }
            let rate = Double(wakeups - startWakeups) / (Double(uptimeNanos - since) / 1e9)
            counts[Self.bucketIndex(rate)] &+= 1
            maxRate = max(maxRate, rate)
            lastRate = rate
            return rate
        }
    }

    /// The bucket that holds `rate`.
    public static func bucketIndex(_ rate: Double) -> Int {
        upperBounds.firstIndex { rate <= $0 } ?? upperBounds.count
    }

    /// The bucket's label: its upper bound, or "50+" for the overflow bucket.
    public static func label(ofBucket index: Int) -> String {
        guard index < upperBounds.count else { return "\(Self.formatted(upperBounds[upperBounds.count - 1]))+" }
        return formatted(upperBounds[index])
    }

    /// The `fraction` percentile (0.5 for p50) as the upper bound of the bucket that holds it, the
    /// highest rate seen for the overflow bucket; nil before the first sample.
    public func percentile(_ fraction: Double) -> Double? {
        let total = sampleCount
        guard total > 0 else { return nil }
        let rank = max(1, UInt64((fraction * Double(total)).rounded(.up)))
        var seen: UInt64 = 0
        for (index, count) in counts.enumerated() {
            seen &+= count
            if seen >= rank { return index < Self.upperBounds.count ? Self.upperBounds[index] : maxRate }
        }
        return maxRate
    }

    /// A clock that went back has not elapsed.
    private static func elapsed(_ uptimeNanos: UInt64, since start: UInt64, atLeast span: UInt64) -> Bool {
        uptimeNanos >= start && uptimeNanos - start >= span
    }

    private static func formatted(_ bound: Double) -> String {
        bound == bound.rounded() ? String(Int(bound)) : String(bound)
    }
}

/// Feeds ``IdleEnergyStats`` from the main run loop's wakes. The App builds one per launch in its
/// energy owner (`EnergyServices`) and starts it at launch; `debug.energy` reads its ``stats``.
///
/// It adds one `afterWaiting` observer and no timer: an observer runs only in passes that other
/// work started. Each wake costs one uptime read, one relaxed input-count load and a compare; the
/// wakeup counter is read only when a window opens or closes.
@MainActor
public final class IdleEnergyMonitor {
    /// Where the monitor reads its counters (the tests' seam).
    public struct Sources: Sendable {
        /// Monotonic nanoseconds, `CLOCK_UPTIME_RAW`.
        public var uptimeNanos: @Sendable () -> UInt64
        /// The main process's interrupt wakeups, nil when `proc_pid_rusage` fails.
        public var interruptWakeups: @Sendable () -> UInt64?
        /// The input events dispatched since launch: a change means the person was not idle.
        public var inputEvents: @Sendable () -> UInt64

        /// The sources the monitor reads.
        public init(uptimeNanos: @escaping @Sendable () -> UInt64,
                    interruptWakeups: @escaping @Sendable () -> UInt64?,
                    inputEvents: @escaping @Sendable () -> UInt64) {
            self.uptimeNanos = uptimeNanos
            self.interruptWakeups = interruptWakeups
            self.inputEvents = inputEvents
        }

        /// This process's counters through ``ProcessUsage``, the counter `debug.energy`'s
        /// `processes` uses; `activity` is the one the app's input monitor notes into.
        public static func live(activity: ExpectedActivity) -> Sources {
            let pid = getpid()
            return Sources(uptimeNanos: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                           interruptWakeups: { ProcessUsage.interruptWakeups(of: pid) },
                           inputEvents: { activity.count(.input) })
        }
    }

    /// Adds `onWake` at each main run loop stage in `activities` and returns the token that keeps
    /// it; releasing the token removes it (``mainRunLoopWakes(_:_:)`` in the app, a fake in tests).
    public typealias WakeRegistration = @MainActor (_ activities: CFRunLoopActivity, _ onWake: @escaping @MainActor () -> Void) -> AnyObject

    /// The histogram of idle wake rates recorded this launch.
    public private(set) var stats = IdleEnergyStats()
    private let sources: Sources
    private let observeWakes: WakeRegistration
    private var observation: AnyObject?

    /// A monitor that records nothing until ``start()``.
    ///
    /// - Parameters:
    ///   - sources: The counters (``Sources/live(activity:)`` in the app).
    ///   - observeWakes: Adds the wake handler (``mainRunLoopWakes(_:_:)`` by default).
    public init(sources: Sources, observeWakes: @escaping WakeRegistration = IdleEnergyMonitor.mainRunLoopWakes) {
        self.sources = sources
        self.observeWakes = observeWakes
    }

    /// A ``MainRunLoopObserver`` of `activities` that calls `onWake`.
    public static func mainRunLoopWakes(_ activities: CFRunLoopActivity, _ onWake: @escaping @MainActor () -> Void) -> AnyObject {
        MainRunLoopObserver(activities: activities) { _ in onWake() }
    }

    /// Starts recording at the main run loop's wakes: one `afterWaiting` handler and nothing else.
    /// Calling it again does nothing.
    public func start() {
        guard observation == nil else { return }
        observation = observeWakes(.afterWaiting) { [weak self] in self?.noteWake() }
    }

    /// Stops recording; the histogram stays.
    public func stop() {
        observation = nil
    }

    /// One main run loop wake (the observer; tests call it directly).
    public func noteWake() { // perf-hot: 0.1us idle-energy-wake (every main run loop wake; one rusage read only when a window opens or closes)
        stats.noteWake(at: sources.uptimeNanos(), inputEvents: sources.inputEvents(), interruptWakeups: sources.interruptWakeups)
    }
}
