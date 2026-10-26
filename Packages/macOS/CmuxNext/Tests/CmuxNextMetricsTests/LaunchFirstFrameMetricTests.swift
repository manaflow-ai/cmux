import CmuxNextMetrics
import Testing

/// `launch.first_frame.<temperature>` from a launch clock (task 058): the uptime arithmetic and the
/// histogram each temperature picks.
@MainActor
@Suite("Launch first frame metric")
struct LaunchFirstFrameMetricTests {
    @Test("The sample is now minus the process start, in the temperature's histogram",
          arguments: HistogramID.LaunchTemperature.allCases)
    func recordsSinceProcessStart(_ temperature: HistogramID.LaunchTemperature) {
        let recorder = Recorder()
        LaunchFirstFrameMetric(processStart: { .seconds(100) }, temperature: { temperature },
                               now: { .seconds(100) + .milliseconds(740) }, record: recorder.record).recordFirstFrame()
        #expect(recorder.samples.map { $0.0 } == [.launchFirstFrame(temperature)])
        #expect(recorder.samples.map { $0.0.name } == ["launch.first_frame." + temperature.rawValue])
        #expect(recorder.samples.map { $0.1 } == [.milliseconds(740)])
    }

    @Test("An unknown start or temperature records nothing")
    func unknownLaunchRecordsNothing() {
        let recorder = Recorder()
        LaunchFirstFrameMetric(processStart: { nil }, temperature: { .cold }, now: { .seconds(5) },
                               record: recorder.record).recordFirstFrame()
        LaunchFirstFrameMetric(processStart: { .seconds(1) }, temperature: { nil }, now: { .seconds(5) },
                               record: recorder.record).recordFirstFrame()
        LaunchFirstFrameMetric.notMeasured.recordFirstFrame()
        #expect(recorder.samples.isEmpty)
    }

    @Test("A start after now (another clock) records nothing")
    func startAfterNowRecordsNothing() {
        let recorder = Recorder()
        LaunchFirstFrameMetric(processStart: { .seconds(9) }, temperature: { .warm }, now: { .seconds(5) },
                               record: recorder.record).recordFirstFrame()
        #expect(recorder.samples.isEmpty)
    }
}

/// The histogram samples a metric records.
@MainActor
private final class Recorder {
    private(set) var samples: [(HistogramID, Duration)] = []

    var record: @MainActor @Sendable (HistogramID, Duration) -> Void {
        { [self] in samples.append(($0, $1)) }
    }
}
