/// `launch.first_frame.<temperature>`: the process start to the first window's first committed frame, in
/// the startup temperature's histogram (task 058). Chrome records `Startup.FirstWebContents.NonEmptyPaint3`
/// split by `UmaHistogramWithTemperature` (components/startup_metric_utils/browser/startup_metric_utils.cc).
///
/// The app's `FirstFrameGate` calls ``recordFirstFrame()`` once, at the first committed frame of a launch
/// that was not interrupted. The composition root builds the metric from the process's one launch clock
/// (task 034) and its metrics file; tests inject fixed values and a recording spy.
///
/// ```swift
/// let metric = LaunchFirstFrameMetric(processStart: { clock.processStart }, temperature: { clock.temperature },
///                                     now: { uptime() }, record: { metrics.record($0, duration: $1) })
/// metric.recordFirstFrame()
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

    /// A metric that measures `now - processStart` on one uptime clock, in the startup temperature's
    /// histogram. Nothing is measured while the start or the temperature is unknown, or when the start
    /// is after `now` (a start from another clock).
    /// - Parameters:
    ///   - processStart: The process start, as uptime.
    ///   - temperature: The startup temperature sampled at the first main run-loop turn.
    ///   - now: The current uptime, on the clock of `processStart`.
    ///   - record: Records one sample of a histogram.
    public init(processStart: @escaping @MainActor @Sendable () -> Duration?,
                temperature: @escaping @MainActor @Sendable () -> HistogramID.LaunchTemperature?,
                now: @escaping @MainActor @Sendable () -> Duration,
                record: @escaping @MainActor @Sendable (HistogramID, Duration) -> Void) {
        self.init(measure: {
            guard let start = processStart(), let temperature = temperature() else { return nil }
            let elapsed = now() - start
            return elapsed >= .zero ? (elapsed, temperature) : nil
        }, record: record)
    }

    /// Measures now and records the sample; records nothing when the launch is unknown.
    @MainActor public func recordFirstFrame() {
        guard let sample = measure() else { return }
        record(.launchFirstFrame(sample.temperature), sample.sinceProcessStart)
    }

    /// Measures and records nothing: a process with no launch clock.
    public static let notMeasured = Self(measure: { nil }, record: { _, _ in })
}
