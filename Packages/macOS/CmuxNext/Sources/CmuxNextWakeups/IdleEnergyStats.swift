import CmuxNextCompat
import CoreFoundation
import Darwin

/// The app's idle interrupt wakeups per second over this launch, as a histogram with fixed
/// buckets (p14-energy-008, `debug.energy`'s `idle`).
///
/// Chrome samples the same counter (`ProcessMetrics::GetIdleWakeupsPerSecond` in
/// `base/process/process_metrics_apple.mm` reads `TASK_POWER_INFO`'s `task_interrupt_wakeups`)
/// from the repeating timer of `chrome/browser/performance_monitor/process_monitor.cc` and records
/// it into the `PerformanceMonitor.IdleWakeups` histogram
/// (`chrome/browser/performance_monitor/process_metrics_recorder_util.cc`). cmux has no timer for
/// it: the window closes at the first main run loop wake that other work starts once 60 s have
/// passed, so an idle app wakes no more often to measure itself.
///
/// A window holds one sample only when no input arrived in it; one with input is dropped, so the
/// histogram describes the app with nobody using it.
public struct IdleEnergyStats: Sendable, Equatable {
    /// The counters read at the start and end of a window.
    public struct Reading: Sendable, Equatable {
        /// `CLOCK_UPTIME_RAW` nanoseconds (stops while the Mac sleeps, as the wakeup counter does).
        public var uptimeNanos: UInt64
        /// The app's interrupt wakeups since it started (`task_interrupt_wakeups`).
        public var interruptWakeups: UInt64
        /// The app's input events since it started (``ExpectedActivity``'s `.input` count).
        public var inputEvents: UInt64

        public init(uptimeNanos: UInt64, interruptWakeups: UInt64, inputEvents: UInt64) {
            self.uptimeNanos = uptimeNanos
            self.interruptWakeups = interruptWakeups
            self.inputEvents = inputEvents
        }
    }

    /// The shortest window: a sample covers at least one idle minute.
    public static let windowNanos: UInt64 = 60 * 1_000_000_000

    /// The upper bounds (inclusive, wakeups/s) of every bucket but the last; the last bucket holds
    /// every rate above 50 ("50+"). 0.2/s falls in the 0.25 bucket.
    public static let upperBounds: [Double] = [0, 0.1, 0.25, 0.5, 1, 2, 5, 10, 50]

    /// Samples per bucket: `upperBounds.count + 1` entries, the overflow bucket last.
    public private(set) var counts = [UInt64](repeating: 0, count: IdleEnergyStats.upperBounds.count + 1)
    /// Windows dropped because input arrived in them.
    public private(set) var windowsWithInput: UInt64 = 0
    /// The highest rate recorded (the overflow bucket's percentile value).
    public private(set) var maxRate: Double = 0
    /// The last rate recorded, nil before the first sample.
    public private(set) var lastRate: Double?
    private var start: Reading?

    public init() {}

    /// Samples recorded this launch.
    public var sampleCount: UInt64 { counts.reduce(0, &+) }

    /// Whether a wake at `uptimeNanos` closes the window (or opens the first one). The only check
    /// that runs on every wake: no counter is read until it is true.
    public func isWindowDue(at uptimeNanos: UInt64) -> Bool {
        guard let start else { return true }
        return uptimeNanos &- start.uptimeNanos >= Self.windowNanos
    }

    /// Closes the window at `reading` and opens the next one there. Records the window's rate and
    /// returns it when the window had no input; returns nil for the first reading and for a window
    /// with input.
    @discardableResult
    public mutating func close(at reading: Reading) -> Double? {
        defer { start = reading }
        guard let start, reading.uptimeNanos > start.uptimeNanos, reading.interruptWakeups >= start.interruptWakeups else {
            return nil
        }
        guard reading.inputEvents == start.inputEvents else {
            windowsWithInput &+= 1
            return nil
        }
        let seconds = Double(reading.uptimeNanos - start.uptimeNanos) / 1e9
        let rate = Double(reading.interruptWakeups - start.interruptWakeups) / seconds
        counts[Self.bucketIndex(rate)] &+= 1
        maxRate = max(maxRate, rate)
        lastRate = rate
        return rate
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

    private static func formatted(_ bound: Double) -> String {
        bound == bound.rounded() ? String(Int(bound)) : String(bound)
    }
}

/// Feeds ``IdleEnergyStats`` from the main run loop's wakes (the app's `debug.energy` report owns one).
///
/// It adds one `afterWaiting` observer and no timer: an observer runs only in passes that other
/// work started. Each wake costs one uptime read and a compare; the wakeup and input counters are
/// read once per closed window.
@MainActor
public final class IdleEnergyMonitor {
    /// Where the monitor reads its counters (the tests' seam).
    public struct Sources: Sendable {
        public var uptimeNanos: @Sendable () -> UInt64
        /// The app's interrupt wakeups, nil when `task_info` fails.
        public var interruptWakeups: @Sendable () -> UInt64?
        public var inputEvents: @Sendable () -> UInt64

        public init(uptimeNanos: @escaping @Sendable () -> UInt64,
                    interruptWakeups: @escaping @Sendable () -> UInt64?,
                    inputEvents: @escaping @Sendable () -> UInt64) {
            self.uptimeNanos = uptimeNanos
            self.interruptWakeups = interruptWakeups
            self.inputEvents = inputEvents
        }

        /// This process's counters; `activity` is the one the app's input monitor notes into.
        public static func live(activity: ExpectedActivity) -> Sources {
            Sources(uptimeNanos: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                    interruptWakeups: { Self.ownInterruptWakeups() },
                    inputEvents: { activity.count(.input) })
        }

        /// `task_interrupt_wakeups` of this task (`TASK_POWER_INFO`), the counter Chrome reads. A
        /// Mach call on the caller's own task: no I/O and no lock the caller could wait on.
        private static func ownInterruptWakeups() -> UInt64? {
            var info = task_power_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.task_interrupt_wakeups : nil
        }
    }

    public private(set) var stats = IdleEnergyStats()
    private let sources: Sources
    private var observer: MainRunLoopObserver?

    public init(sources: Sources) {
        self.sources = sources
    }

    /// Starts recording at the main run loop's wakes. Calling it again does nothing.
    public func start() {
        guard observer == nil else { return }
        observer = MainRunLoopObserver(activities: .afterWaiting) { [weak self] _ in self?.noteWake() }
    }

    /// Stops recording; the histogram stays.
    public func stop() {
        observer = nil
    }

    /// One main run loop wake (the observer; tests call it directly).
    public func noteWake() {
        let now = sources.uptimeNanos()
        guard stats.isWindowDue(at: now), let wakeups = sources.interruptWakeups() else { return }
        stats.close(at: IdleEnergyStats.Reading(uptimeNanos: now, interruptWakeups: wakeups, inputEvents: sources.inputEvents()))
    }
}
