public import CmuxNextTrace
import Darwin

/// `launch.first_frame.<temperature>`: the process start to the first window's first committed frame, in
/// the startup temperature's histogram (task 058). Chrome records `Startup.FirstWebContents.NonEmptyPaint3`
/// split by `UmaHistogramWithTemperature` (components/startup_metric_utils/browser/startup_metric_utils.cc).
///
/// The app's `FirstFrameGate` calls ``recordFirstFrame()`` once, at the first committed frame; tests inject
/// a fixed measure and a recording spy.
///
/// ```swift
/// LaunchFirstFrameMetric.live().recordFirstFrame()
/// ```
public struct LaunchFirstFrameMetric: Sendable {
    /// The time since the process start and the startup temperature, or nil when either is unknown (then
    /// nothing is recorded).
    public let measure: @MainActor @Sendable () -> (sinceProcessStart: Duration, temperature: HistogramID.LaunchTemperature)?
    /// Records one sample of a histogram.
    public let record: @MainActor @Sendable (HistogramID, Duration) -> Void

    /// A metric that measures with `measure` and records with `record`.
    public init(measure: @escaping @MainActor @Sendable () -> (sinceProcessStart: Duration, temperature: HistogramID.LaunchTemperature)?,
                record: @escaping @MainActor @Sendable (HistogramID, Duration) -> Void) {
        self.measure = measure
        self.record = record
    }

    /// Measures now and records the sample; records nothing when the launch is unknown.
    @MainActor public func recordFirstFrame() {
        guard let sample = measure() else { return }
        record(.launchFirstFrame(sample.temperature), sample.sinceProcessStart)
    }
}

extension LaunchFirstFrameMetric {
    /// The process's own launch: task 034's `LaunchClock` (the process start as uptime and the temperature
    /// sampled at the first main run-loop turn) and the process's metrics file.
    public static func live(clock: LaunchClock = LaunchClock(), metrics: Metrics = Metrics()) -> Self {
        Self(
            measure: {
                guard let start = clock.processStartUptime,
                      let temperature = clock.startupTemperature.flatMap({ HistogramID.LaunchTemperature(rawValue: $0.rawValue) })
                else { return nil }
                return (.nanoseconds(Int64(clamping: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))) - start, temperature)
            },
            record: { metrics.record($0, duration: $1) })
    }
}
