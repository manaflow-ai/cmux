import CmuxNextMetrics
public import CmuxNextTrace

/// One launch mark's whole effect on the launch's slices and temperature, split so the owner of the launch-marks
/// lock does only the state change under it: ``Reading`` (the page-ins read, before the lock), ``apply(_:atUptimeNanos:)``
/// (under the lock), ``Step/publish(into:)`` (after it).
///
/// ```swift
/// let reading = LaunchSlices.Reading(mark: name, clock: clock)
/// let step = lock.withLock { $0.apply(reading, atUptimeNanos: now) }
/// step.publish(into: .shared)
/// if let instant = step.temperatureInstant { sendMark(instant) }
/// ```
nonisolated extension LaunchSlices {
    /// The prefix of the instant time mark that names the decided temperature, `launch.temperature.<name>`, sent at
    /// ``temperatureMark``'s time (scripts/cmux-next/bench-startup.py `TEMPERATURE_INSTANT`).
    public static let temperatureInstantPrefix = "launch.temperature."
    /// The value mark of the page-ins the temperature came from (bench-startup.py `PAGEINS_RUN_LOOP`).
    public static let pageinsValueMark = "launch.pageins_run_loop_start"

    /// What a launch mark reads before its owner takes the lock: the milestone it reaches, and the page-ins when it
    /// is ``temperatureMark`` (read before that mark's own work, as Chrome reads them at its message-loop start).
    public struct Reading: Sendable, Equatable {
        /// The milestone the mark reaches, or nil.
        public let milestone: Milestone?
        /// Whether the mark is ``temperatureMark``.
        public let samplesTemperature: Bool
        /// The page-ins `clock` read, nil when the mark samples nothing or the count could not be read.
        public let pageins: UInt64?
        /// Whether the mark is ``interruptedMark``.
        public let interrupts: Bool

        /// Reads the page-ins from `clock` only for ``temperatureMark``.
        public init(mark: String, clock: LaunchClock) {
            milestone = Milestone(mark: mark)
            samplesTemperature = mark == LaunchSlices.temperatureMark
            pageins = samplesTemperature ? clock.pageins() : nil
            interrupts = mark == LaunchSlices.interruptedMark
        }
    }

    /// What one launch mark produced: the slices to write, and the temperature when this mark decided it.
    public struct Step: Sendable, Equatable {
        /// The slices to write, in the order their milestones came.
        public var slices: [Slice] = []
        /// The temperature this mark decided; nil at every other mark.
        public var temperature: LaunchClock.Temperature?
        /// The page-ins it was decided from; nil at every other mark or when they could not be read.
        public var pageins: UInt64?
        /// Whether the launch was interrupted when this mark came (``interruptedMark``).
        public var interrupted = false

        /// A mark that changed nothing.
        public init() {}

        /// The bench's instant mark for the decided temperature (``temperatureInstantPrefix`` and its name).
        public var temperatureInstant: String? {
            temperature.map { LaunchSlices.temperatureInstantPrefix + $0.name }
        }

        /// The `launch.pageins` sample this mark records, nil when it decided no temperature or read no count.
        public var pageinsSample: Int64? {
            temperature == nil ? nil : pageins.map { Int64(clamping: $0) }
        }

        /// The `launch.first_frame.<temperature>` sample this mark records: the first-frame slice's length, the
        /// process start to the first window's first committed frame, in its temperature's histogram. Nil when the
        /// mark released no first-frame slice, the launch was interrupted, or the temperature is undetermined. Chrome
        /// records `Startup.FirstWebContents.NonEmptyPaint3` only when `ShouldLogStartupHistogram` (no interrupted
        /// launch), and per temperature (`UmaHistogramWithTemperature`) only for a determined one
        /// (components/startup_metric_utils/browser/startup_metric_utils.cc).
        var firstFrameSample: (temperature: HistogramID.LaunchTemperature, duration: Duration)? {
            guard !interrupted, let slice = slices.first(where: { $0.name == .launchFirstFrame }),
                  let temperature = HistogramID.LaunchTemperature(slice.temperature) else { return nil }
            return (temperature, .nanoseconds(slice.endNanos - slice.beginNanos))
        }

        /// Writes the slices into `runtime`'s ring and records `launch.pageins` and `launch.first_frame.<temperature>`
        /// into its metrics.
        public func publish(into runtime: TraceRuntime) {
            for slice in slices {
                slice.record(into: runtime)
            }
            if let pageinsSample {
                Metrics(runtime: runtime).record(.launchPageins, pageinsSample)
            }
            if let firstFrame = firstFrameSample {
                Metrics(runtime: runtime).record(.launchFirstFrame(firstFrame.temperature), duration: firstFrame.duration)
            }
        }
    }

    /// Applies one launch mark: ends its milestone's slice, at ``interruptedMark`` interrupts the launch, and at
    /// ``temperatureMark`` decides the temperature and releases the slices that waited for it. The owner calls it once
    /// per mark name.
    public mutating func apply(_ reading: Reading, atUptimeNanos endNanos: UInt64) -> Step {
        var step = Step()
        if reading.interrupts { interrupt() }
        step.interrupted = interrupted
        if let milestone = reading.milestone, let slice = reach(milestone, atUptimeNanos: endNanos) {
            step.slices.append(slice)
        }
        if reading.samplesTemperature, temperature == nil {
            step.slices += sample(pageins: reading.pageins)
            step.temperature = temperature
            step.pageins = pageins
        }
        return step
    }
}
