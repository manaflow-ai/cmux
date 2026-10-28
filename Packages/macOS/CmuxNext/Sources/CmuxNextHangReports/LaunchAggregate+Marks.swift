/// One launch read from its launch marks (CmuxNextLaunch's `LaunchMarks`, which the app's `DebugTimings.markLaunch`
/// records once per name, in milliseconds since process start), as Chrome's `startup_metric_utils` reads its
/// milestones (components/startup_metric_utils/browser/startup_metric_utils.cc).
///
/// ```swift
/// // at startup_complete, after LaunchOrder marked startup_complete.<reason> and startup_complete:
/// let record = LaunchAggregate.Record(marks: DebugTimings.launchMarksNow.all)
/// ```
extension LaunchAggregate.Record {
    /// The first window's first committed frame.
    public static let firstFrameMark = "first_window_frame_committed"
    /// The first frame of live pane content.
    public static let liveContentMark = "first_live_content_frame"
    /// Startup completed (`LaunchOrder`); `startup_complete.<reason>` comes just before it.
    public static let startupCompleteMark = "startup_complete"
    /// The launch was interrupted (p08-startup-108: a hidden or windowless launch).
    public static let interruptedMark = "launch.interrupted"
    /// The temperature's instant mark: this prefix and the temperature's name (p08-startup-007).
    public static let temperatureMarkPrefix = "launch.temperature."

    /// The launch `marks` describe, each a name and its milliseconds since process start. Nil before
    /// ``startupCompleteMark``, or when the completion reason (`startup_complete.<reason>`) is not a
    /// ``LaunchCompletionReason``. No temperature mark is ``LaunchTemperature/undetermined``.
    public init?(marks: [(name: String, ms: Double)]) {
        var times: [String: Double] = [:]
        for mark in marks where times[mark.name] == nil { times[mark.name] = mark.ms }
        let reasonPrefix = Self.startupCompleteMark + "."
        guard let startupComplete = times[Self.startupCompleteMark],
              let reasonMark = marks.first(where: { $0.name.hasPrefix(reasonPrefix) }),
              let reason = LaunchCompletionReason(rawValue: String(reasonMark.name.dropFirst(reasonPrefix.count))) else { return nil }
        let temperature = marks.first { $0.name.hasPrefix(Self.temperatureMarkPrefix) }
            .flatMap { LaunchTemperature(rawValue: String($0.name.dropFirst(Self.temperatureMarkPrefix.count))) } ?? .undetermined
        self.init(temperature: temperature, interrupted: times[Self.interruptedMark] != nil,
                  firstFrame: times[Self.firstFrameMark].map(Self.duration), liveContent: times[Self.liveContentMark].map(Self.duration),
                  startupComplete: Self.duration(startupComplete), reason: reason)
    }

    /// `ms` as a duration, clamped to `0...HistogramBucket.maxMs` (a mark before process start is 0).
    static func duration(_ ms: Double) -> Duration {
        guard ms.isFinite, ms > 0 else { return .zero }
        return .microseconds(Int64((min(ms, Double(HistogramBucket.maxMs)) * 1_000).rounded()))
    }
}
