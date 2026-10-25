import Darwin

/// How much of a launch had to come from disk: Chrome's `StartupTemperature`
/// (components/startup_metric_utils/common/startup_metric_utils.h), decided once at
/// the main run loop's start from the process's page-ins. Launch statistics are
/// split by it, so a cold launch never hides in a warm median.
public nonisolated enum StartupTemperature: String, Sendable, CaseIterable {
    case cold
    case warm
    case lukewarm
    /// The page-in count could not be read.
    case undetermined

    /// The page-in bounds of each temperature.
    public nonisolated struct Thresholds: Sendable, Equatable {
        /// Fewer page-ins than this is warm.
        public var warmBelow: UInt64
        /// This many page-ins or more is cold; between the two is lukewarm.
        public var coldFrom: UInt64

        public init(warmBelow: UInt64, coldFrom: UInt64) {
            self.warmBelow = warmBelow
            self.coldFrom = coldFrom
        }

        /// Chrome's split, the start point until the fleet's cold and warm launches tune it:
        /// `kWarmStartHardFaultCountThreshold` (5) and `kColdStartHardFaultCountThreshold` (3500) in
        /// components/startup_metric_utils/browser/startup_metric_utils.cc. Chrome reads the same
        /// counter on macOS (`task_info(TASK_EVENTS_INFO).pageins`).
        public static let chrome = Self(warmBelow: 5, coldFrom: 3_500)

        /// Chrome's order in `RecordHardFaultHistogram`: warm first, then cold, else lukewarm.
        public func classify(pageIns: UInt64?) -> StartupTemperature {
            guard let pageIns else { return .undetermined }
            if pageIns < warmBelow { return .warm }
            if pageIns >= coldFrom { return .cold }
            return .lukewarm
        }
    }
}

/// The counters a launch reads at its milestones. Tests give their own values.
public nonisolated protocol LaunchCounterSource: Sendable {
    /// This process's page-ins since it started; nil when unreadable.
    func pageIns() -> UInt64?
    /// The main thread's CPU time (user plus system) in nanoseconds, from any thread; nil when unreadable.
    func mainThreadCPUNanos() -> UInt64?
}

/// Reads the launch counters at their milestones and classifies the temperature.
/// The caller reads first, before any other work of the milestone, so that work never
/// reaches the counters; the reads are the only work here.
public nonisolated struct StartupCounterReader: Sendable {
    /// The milestone that decides the temperature (Chrome: `RecordBrowserMainMessageLoopStart`).
    public static let runLoopStartMilestone = "run_loop_start"
    /// The milestone of the separate first-frame values (Chrome: `Startup.BrowserWindowFirstPaintHardFaultCount`).
    public static let firstFrameMilestone = "first_window_frame_committed"

    private let source: any LaunchCounterSource
    private let thresholds: StartupTemperature.Thresholds

    public init(source: any LaunchCounterSource = SystemCounters(), thresholds: StartupTemperature.Thresholds = .chrome) {
        self.source = source
        self.thresholds = thresholds
    }

    /// The sample of `milestone`, or nil (and no read) for every other milestone.
    public func sample(atMilestone milestone: String) -> Sample? {
        switch milestone {
        case Self.runLoopStartMilestone:
            let pageIns = source.pageIns()
            return Sample(temperature: thresholds.classify(pageIns: pageIns),
                          values: pageIns.map { [Sample.Value(name: "launch.pageins_run_loop_start", value: Double($0))] } ?? [])
        case Self.firstFrameMilestone:
            let pageIns = source.pageIns()
            let cpuNanos = source.mainThreadCPUNanos()
            var values: [Sample.Value] = []
            if let pageIns { values.append(Sample.Value(name: "launch.pageins_first_frame", value: Double(pageIns))) }
            if let cpuNanos { values.append(Sample.Value(name: "launch.main_cpu_ms", value: Double(cpuNanos) / 1_000_000)) }
            return Sample(temperature: nil, values: values)
        default:
            return nil
        }
    }

    /// What one milestone read: the temperature (at `run_loop_start` only) and the counter
    /// values, each named as the launch marks pipe and `debug.timings` carry it.
    public nonisolated struct Sample: Sendable, Equatable {
        public nonisolated struct Value: Sendable, Equatable {
            public var name: String
            public var value: Double

            public init(name: String, value: Double) {
                self.name = name
                self.value = value
            }
        }

        public var temperature: StartupTemperature?
        public var values: [Value]

        public init(temperature: StartupTemperature?, values: [Value]) {
            self.temperature = temperature
            self.values = values
        }

        /// The instant mark of the temperature, like Chrome's `Startup.Temperature.<T>` trace event.
        public var temperatureMark: String? { temperature.map { "launch.temperature.\($0.rawValue)" } }
    }

    /// The kernel's counters: `ri_pageins` of `proc_pid_rusage(RUSAGE_INFO_V4)` and the main
    /// thread's `THREAD_BASIC_INFO`. Each read is one syscall and allocates nothing.
    public nonisolated struct SystemCounters: LaunchCounterSource {
        public init() {}

        public func pageIns() -> UInt64? {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return status == 0 ? info.ri_pageins : nil
        }

        public func mainThreadCPUNanos() -> UInt64? {
            // pthread_mach_thread_np returns the thread's own port: no reference to release.
            let thread = pthread_mach_thread_np(pthread_main_thread_np())
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
