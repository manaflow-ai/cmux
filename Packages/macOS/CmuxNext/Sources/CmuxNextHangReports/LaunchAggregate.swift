/// The launches since the last report: three milestone histograms split by ``LaunchTemperature``
/// and a count per ``LaunchCompletionReason``, in their wire form, so the aggregate is saved with
/// the watchdog's for the next launch and copied into a report as it is.
///
/// Like Chrome (`components/startup_metric_utils/browser/startup_metric_utils.cc`), an
/// interrupted launch (a hidden or occluded window, a dialog first, a first run;
/// `WasMainWindowStartupInterrupted`) is left out of the duration histograms; its completion
/// reason is still counted, as `Startup.BrowserStartupCompleteReason` is for every launch.
///
/// ```swift
/// var launches = LaunchAggregate()
/// launches.record(LaunchAggregate.Record(temperature: .warm, interrupted: false, firstFrame: .milliseconds(240),
///                                        liveContent: .milliseconds(310), startupComplete: .milliseconds(420),
///                                        reason: .visiblePaneLoadedIdle))
/// ```
public nonisolated struct LaunchAggregate: Codable, Sendable, Equatable {
    /// One launch, as the app hands it over at `startup_complete`. Durations are from process start.
    public struct Record: Sendable, Equatable {
        /// The temperature decided at `run_loop_start`.
        public var temperature: LaunchTemperature
        /// Whether something other than cmux's own work slowed the launch.
        public var interrupted: Bool
        /// To `first_window_frame_committed`; nil when no window showed.
        public var firstFrame: Duration?
        /// To `first_live_content_frame`; nil when no pane showed live content before completion.
        public var liveContent: Duration?
        /// To `startup_complete`.
        public var startupComplete: Duration
        /// Why startup completed.
        public var reason: LaunchCompletionReason

        /// Makes the value from its parts.
        public init(temperature: LaunchTemperature, interrupted: Bool, firstFrame: Duration?, liveContent: Duration?,
                    startupComplete: Duration, reason: LaunchCompletionReason) {
            self.temperature = temperature
            self.interrupted = interrupted
            self.firstFrame = firstFrame
            self.liveContent = liveContent
            self.startupComplete = startupComplete
            self.reason = reason
        }
    }

    /// Histogram edges in milliseconds: buckets are `[0, 100)`, `[100, 200)`, ..., `[60000, one day)`.
    public static let bucketEdgesMs = [0, 100, 200, 300, 400, 500, 600, 800, 1_000, 1_250, 1_500, 2_000, 2_500, 3_000,
                                       4_000, 5_000, 7_500, 10_000, 15_000, 20_000, 30_000, 60_000]

    /// Process start to the first committed window frame, by temperature.
    public private(set) var launchFirstFrame: [LaunchHistogram] = []
    /// Process start to `startup_complete`, by temperature.
    public private(set) var launchStartupComplete: [LaunchHistogram] = []
    /// Process start to the first frame of live pane content, by temperature.
    public private(set) var launchLiveContent: [LaunchHistogram] = []
    /// Completed launches per reason, interrupted ones included.
    public private(set) var completionReasons: [LaunchReasonCount] = []

    /// Makes the value from its parts.
    public init() {}

    /// Whether no launch was recorded.
    public var isEmpty: Bool {
        launchFirstFrame.isEmpty && launchStartupComplete.isEmpty && launchLiveContent.isEmpty && completionReasons.isEmpty
    }

    /// Counts one launch.
    public mutating func record(_ launch: Record) {
        completionReasons = LaunchReasonCount.merged(completionReasons + [LaunchReasonCount(reason: launch.reason, count: 1)])
        guard !launch.interrupted else { return }
        launchFirstFrame = Self.adding(launch.firstFrame, temperature: launch.temperature, to: launchFirstFrame)
        launchStartupComplete = Self.adding(launch.startupComplete, temperature: launch.temperature, to: launchStartupComplete)
        launchLiveContent = Self.adding(launch.liveContent, temperature: launch.temperature, to: launchLiveContent)
    }

    /// Adds another aggregate (the one saved by the previous launch). Every value is rebuilt
    /// through the bounded initializers, so merging a decoded file into an empty aggregate also
    /// clamps it.
    public mutating func merge(_ other: LaunchAggregate) {
        launchFirstFrame = LaunchHistogram.merged(launchFirstFrame + other.launchFirstFrame)
        launchStartupComplete = LaunchHistogram.merged(launchStartupComplete + other.launchStartupComplete)
        launchLiveContent = LaunchHistogram.merged(launchLiveContent + other.launchLiveContent)
        completionReasons = LaunchReasonCount.merged(completionReasons + other.completionReasons)
    }

    /// The bucket a duration of `milliseconds` falls in, with a count of one.
    static func bucket(milliseconds: Int) -> HistogramBucket {
        let ms = min(max(0, milliseconds), HistogramBucket.maxMs)
        let index = bucketEdgesMs.lastIndex { ms >= $0 } ?? 0
        let high = index + 1 < bucketEdgesMs.count ? bucketEdgesMs[index + 1] : HistogramBucket.maxMs
        return HistogramBucket(lowMs: bucketEdgesMs[index], highMs: high, count: 1)
    }

    /// Whole milliseconds of `duration`, clamped to `0...HistogramBucket.maxMs`.
    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        guard seconds < Int64(HistogramBucket.maxMs / 1_000) else { return HistogramBucket.maxMs }
        return max(0, Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000))
    }

    private static func adding(_ duration: Duration?, temperature: LaunchTemperature,
                               to histograms: [LaunchHistogram]) -> [LaunchHistogram] {
        guard let duration else { return histograms }
        let one = LaunchHistogram(temperature: temperature, count: 1, buckets: [bucket(milliseconds: milliseconds(duration))])
        return LaunchHistogram.merged(histograms + [one])
    }
}
