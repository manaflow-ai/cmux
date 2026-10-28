import Darwin

/// When the kernel started this process, on the trace clock, and how much of the launch came from disk (its
/// startup temperature): the two numbers every `launch.*` slice is measured from and split by.
///
/// Chrome does the same in components/startup_metric_utils: the process creation time is a wall-clock time
/// (`base::Process::CreationTime`) that `StartupTimeToTimeTicks` moves onto `TimeTicks` through one paired
/// read of both clocks (common/startup_metric_utils.cc), and the temperature is the page-in count
/// `task_info(TASK_EVENTS_INFO).pageins` read at the browser's message-loop start, warm below
/// `kWarmStartHardFaultCountThreshold` (5) and cold from `kColdStartHardFaultCountThreshold` (3500)
/// (browser/startup_metric_utils.cc, `RecordHardFaultHistogram`).
///
/// ```swift
/// let clock = LaunchClock()
/// let start = clock.processStart() ?? clock.now()
/// let temperature = LaunchClock.Temperature(pageins: clock.pageins())
/// ```
public nonisolated struct LaunchClock: Sendable {
    /// The system reads, injected by tests.
    public struct Reader: Sendable {
        /// The kernel's start time of this process in wall-clock nanoseconds since 1970, nil when unreadable.
        public let processStartWallNanos: @Sendable () -> UInt64?
        /// Wall-clock nanoseconds since 1970 now.
        public let wallNanos: @Sendable () -> UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds now (the trace clock).
        public let uptimeNanos: @Sendable () -> UInt64
        /// This process's page-ins since it started, nil when unreadable.
        public let pageins: @Sendable () -> UInt64?

        public init(
            processStartWallNanos: @escaping @Sendable () -> UInt64?,
            wallNanos: @escaping @Sendable () -> UInt64,
            uptimeNanos: @escaping @Sendable () -> UInt64,
            pageins: @escaping @Sendable () -> UInt64?
        ) {
            self.processStartWallNanos = processStartWallNanos
            self.wallNanos = wallNanos
            self.uptimeNanos = uptimeNanos
            self.pageins = pageins
        }
    }

    /// One moment on both clocks.
    public struct Instant: Sendable, Equatable {
        /// Wall-clock nanoseconds since 1970.
        public let wallNanos: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds, the clock of every ring record (``TraceClock``).
        public let uptimeNanos: UInt64

        public init(wallNanos: UInt64, uptimeNanos: UInt64) {
            self.wallNanos = wallNanos
            self.uptimeNanos = uptimeNanos
        }
    }

    /// How much of a launch had to come from disk, from the page-ins at the main run loop's start. The raw
    /// value is the code a `launch.*` slice's end record carries in `arg0` (0 warm, 1 lukewarm, 2 cold,
    /// 3 undetermined, as `SignpostName` documents).
    ///
    /// The launch's one classifier: the hang report's `LaunchTemperature` and the metrics'
    /// `HistogramID.LaunchTemperature` are built from it (`init(_:)` in their modules), and the bench reads its
    /// ``name`` (`launch.temperature.<name>`).
    public enum Temperature: UInt8, Sendable, CaseIterable {
        /// Fewer than ``warmPageinsBelow`` page-ins: the app's pages were in memory.
        case warm = 0
        /// Between the two thresholds.
        case lukewarm = 1
        /// At least ``coldPageinsFrom`` page-ins: most pages came from disk.
        case cold = 2
        /// The page-in count could not be read (Chrome's `UNDETERMINED_STARTUP_TEMPERATURE`).
        case undetermined = 3

        /// Chrome's `kWarmStartHardFaultCountThreshold`: fewer page-ins than this is a warm launch. Chrome's
        /// figure, not yet calibrated on the fleet's launches (p09-observability.md, open question (e)).
        public static let warmPageinsBelow: UInt64 = 5
        /// Chrome's `kColdStartHardFaultCountThreshold`: this many page-ins or more is a cold launch.
        public static let coldPageinsFrom: UInt64 = 3_500

        /// The temperature of a launch that had `pageins` page-ins at its run loop's start, in Chrome's order:
        /// warm first, then cold, else lukewarm; nil (unreadable) is ``undetermined``.
        public init(pageins: UInt64?) {
            guard let pageins else {
                self = .undetermined
                return
            }
            if pageins < Self.warmPageinsBelow {
                self = .warm
            } else if pageins >= Self.coldPageinsFrom {
                self = .cold
            } else {
                self = .lukewarm
            }
        }

        /// The name reports and benches use.
        public var name: String {
            switch self {
            case .warm: "warm"
            case .lukewarm: "lukewarm"
            case .cold: "cold"
            case .undetermined: "undetermined"
            }
        }
    }

    /// `nil` reads the system.
    private let reader: Reader?

    /// The system's clocks and counters.
    public init() {
        reader = nil
    }

    /// Clocks and counters read through `reader` (tests).
    public init(reader: Reader) {
        self.reader = reader
    }

    /// Now on both clocks: the wall clock read between two uptime reads, paired with their midpoint.
    public func now() -> Instant {
        let before = uptimeNanos()
        let wall = reader?.wallNanos() ?? Self.systemWallNanos()
        let after = uptimeNanos()
        return Instant(wallNanos: wall, uptimeNanos: before &+ (after &- before) / 2)
    }

    /// When the kernel started this process (`proc_pidinfo(PROC_PIDTBSDINFO)`'s `pbi_start_tvsec` and
    /// `pbi_start_tvusec`), with its trace-clock time from ``uptimeNanos(ofWallNanos:pairedWith:)`` and a
    /// pairing read now. nil when the kernel does not answer.
    public func processStart() -> Instant? {
        let startWall = if let reader { reader.processStartWallNanos() } else { Self.systemProcessStartWallNanos() }
        guard let wall = startWall else { return nil }
        return Instant(wallNanos: wall, uptimeNanos: Self.uptimeNanos(ofWallNanos: wall, pairedWith: now()))
    }

    /// This process's page-ins so far (`task_info(TASK_EVENTS_INFO).pageins`, Chrome's macOS hard-fault
    /// count), nil when the kernel does not answer.
    public func pageins() -> UInt64? {
        guard let reader else { return Self.systemPageins() }
        return reader.pageins()
    }

    /// The trace-clock time of the wall-clock time `wallNanos`: `paired`'s uptime less how long before it
    /// `wallNanos` was. A time after `paired` (the wall clock was set back) is `paired`'s uptime; one before
    /// uptime 0 is 0.
    public static func uptimeNanos(ofWallNanos wallNanos: UInt64, pairedWith paired: Instant) -> UInt64 {
        guard wallNanos < paired.wallNanos else { return paired.uptimeNanos }
        let ago = paired.wallNanos - wallNanos
        return ago < paired.uptimeNanos ? paired.uptimeNanos - ago : 0
    }

    private func uptimeNanos() -> UInt64 {
        reader?.uptimeNanos() ?? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    // wall-clock: the kernel's process start is a wall-clock time; this read pairs it onto the uptime clock.
    private static func systemWallNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_REALTIME)
    }

    private static func systemProcessStartWallNanos() -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // blocking-allow: PROC_PIDTBSDINFO of this process copies its in-memory proc fields; no disk, lock or process wait.
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000_000 &+ info.pbi_start_tvusec &* 1_000
    }

    private static func systemPageins() -> UInt64? {
        var info = task_events_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(clamping: info.pageins)
    }
}
