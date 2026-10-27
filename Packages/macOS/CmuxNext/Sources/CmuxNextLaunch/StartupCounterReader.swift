import CmuxNextTrace
import Darwin

/// The counters a launch reads at its first frame. Tests give their own values.
public nonisolated protocol LaunchCounterSource: Sendable {
    /// This process's page-ins since it started; nil when unreadable.
    func pageIns() -> UInt64?
    /// The main thread's CPU time (user plus system) in nanoseconds, read on the main thread (the first frame's
    /// commit completion runs there); nil when unreadable or when called on any other thread.
    func mainThreadCPUNanos() -> UInt64?
}

/// Reads the first frame's launch counters: the page-ins and the main thread's CPU time, as separate values
/// (Chrome: `Startup.BrowserWindowFirstPaintHardFaultCount`, components/startup_metric_utils/browser/
/// startup_metric_utils.cc). The temperature is not read here: `LaunchSlices` (CmuxNextSignposts) decides it from the page-ins
/// at the main run loop's start (``LaunchClock/Temperature``, the launch's one classifier).
/// The caller reads first, before any other work of the milestone, so that work never reaches the counters;
/// the reads are the only work here.
public nonisolated struct StartupCounterReader: Sendable {
    /// The milestone of the first-frame values.
    public static let firstFrameMilestone = "first_window_frame_committed"

    // The value names, as the launch marks pipe, the `launch.value` signpost and `debug.timings` carry them.
    // They are values, never times: scripts/cmux-next/startup-queue.py and bench-startup.py list each in their
    // VALUE_MARKS (scripts/cmux-next/tests/test_startup_queue.py checks it).

    /// The page-ins at the first frame.
    public static let pageInsFirstFrameName = "launch.pageins_first_frame"
    /// The main thread's CPU time at the first frame, in ms.
    public static let mainCPUName = "launch.main_cpu_ms"

    /// One counter value under one of the reader's value names.
    public nonisolated struct Value: Sendable, Equatable {
        public var name: String
        public var value: Double

        public init(name: String, value: Double) {
            self.name = name
            self.value = value
        }
    }

    private let source: any LaunchCounterSource

    public init(source: any LaunchCounterSource = SystemCounters()) {
        self.source = source
    }

    /// The values `milestone` reads (a counter that could not be read is left out), or nil, and no read, for
    /// every milestone but the first frame.
    public func sample(atMilestone milestone: String) -> [Value]? {
        guard milestone == Self.firstFrameMilestone else { return nil }
        let pageIns = source.pageIns()
        let cpuNanos = source.mainThreadCPUNanos()
        var values: [Value] = []
        if let pageIns { values.append(Value(name: Self.pageInsFirstFrameName, value: Double(pageIns))) }
        if let cpuNanos { values.append(Value(name: Self.mainCPUName, value: Double(cpuNanos) / 1_000_000)) }
        return values
    }

    /// The kernel's counters: the page-ins ``LaunchClock`` reads for the temperature
    /// (`task_info(TASK_EVENTS_INFO).pageins`, so the first frame's count compares with the run loop's), and the
    /// main thread's `THREAD_BASIC_INFO`. Each read is one syscall and allocates nothing.
    ///
    /// The SDK has no public call that names the main thread from another thread, so the CPU read is the calling
    /// thread's own, and only on the main thread: `first_window_frame_committed` is marked in a
    /// `CATransaction` main completion, so the first frame's read is there.
    public nonisolated struct SystemCounters: LaunchCounterSource {
        private let clock = LaunchClock()

        public init() {}

        public func pageIns() -> UInt64? {
            clock.pageins()
        }

        public func mainThreadCPUNanos() -> UInt64? {
            // Only the main thread reads its own time; any other caller would read the wrong thread.
            guard pthread_main_np() != 0 else { return nil }
            // pthread_mach_thread_np returns the thread's own port: no reference to release, unlike mach_thread_self().
            let thread = pthread_mach_thread_np(pthread_self())
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return Self.nanos(info.user_time) + Self.nanos(info.system_time)
        }

        private static func nanos(_ time: time_value_t) -> UInt64 {
            UInt64(clamping: time.seconds) * 1_000_000_000 + UInt64(clamping: time.microseconds) * 1_000
        }
    }
}
