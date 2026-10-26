@testable import CmuxNextApp
import CmuxNextMetrics
import CmuxNextWakeups
import Testing
import CmuxNextWakeupsTestSupport

/// Launch work behind the first window frame (perf-launch-memory).
@MainActor
@Suite struct FirstFrameGateTests {
    @Test func workWaitsForTheFirstFrameThenRunsOnceInOrder() {
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()), launchMetric: .notMeasured)
        var ran: [String] = []
        gate.whenOpen { ran.append("updater") }
        gate.whenOpen { ran.append("warm-ups") }
        #expect(ran.isEmpty)
        gate.open()
        gate.open()
        #expect(ran == ["updater", "warm-ups"])
        gate.whenOpen { ran.append("late") }
        #expect(ran == ["updater", "warm-ups", "late"])
    }

    @Test func aLaunchWithNoWindowStillRunsTheWorkAfterTheBackstop() async throws {
        let clock = ManualClock()
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: clock), launchMetric: .notMeasured)
        var ran = 0
        gate.whenOpen { ran += 1 }
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        #expect(ran == 0)
        clock.advance(by: .seconds(3))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        #expect(ran == 1)
    }

    @Test func theFirstFrameCancelsTheBackstop() async throws {
        let clock = ManualClock()
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: clock), launchMetric: .notMeasured)
        var ran = 0
        gate.whenOpen { ran += 1 }
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        gate.open()
        clock.advance(by: .seconds(3))
        for _ in 0..<20 { await Task.yield() }
        #expect(ran == 1)
    }

    // MARK: launch.first_frame.<temperature> (task 058)

    @Test func theFirstFrameRecordsItsLaunchTemperatureOnce() {
        let spy = LaunchSpy(sinceProcessStart: .milliseconds(840), temperature: .cold)
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()), launchMetric: spy.metric)
        gate.open()
        gate.open()
        #expect(spy.records.map { $0.0.name } == ["launch.first_frame.cold"])
        #expect(spy.records.map { $0.1 } == [.milliseconds(840)])
    }

    @Test func eachTemperatureHasItsOwnHistogram() {
        for temperature in HistogramID.LaunchTemperature.allCases {
            let spy = LaunchSpy(sinceProcessStart: .milliseconds(300), temperature: temperature)
            FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()), launchMetric: spy.metric).open()
            #expect(spy.records.map { $0.0 } == [.launchFirstFrame(temperature)])
        }
    }

    @Test func aBackstopOpeningInterruptsTheLaunchSoALaterFrameRecordsNothing() async throws {
        let clock = ManualClock()
        let spy = LaunchSpy(sinceProcessStart: .seconds(600), temperature: .cold)
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: clock), launchMetric: spy.metric)
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        // The person opens the first window minutes later: not a launch sample.
        gate.open()
        #expect(spy.records.isEmpty)
        #expect(spy.measures == 0)
    }

    @Test func aFrameBeforeTheBackstopRecordsAndTheBackstopNeverFires() async throws {
        let clock = ManualClock()
        let spy = LaunchSpy(sinceProcessStart: .milliseconds(900), temperature: .warm)
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: clock), launchMetric: spy.metric)
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        gate.open()
        clock.advance(by: .seconds(3))
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        #expect(spy.records.map { $0.0.name } == ["launch.first_frame.warm"])
        #expect(spy.records.map { $0.1 } == [.milliseconds(900)])
    }

    @Test func anUnknownLaunchRecordsNothingAndStillOpens() {
        let spy = LaunchSpy(sinceProcessStart: nil, temperature: .warm)
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()), launchMetric: spy.metric)
        var ran = 0
        gate.whenOpen { ran += 1 }
        gate.open()
        #expect(gate.isOpen)
        #expect(ran == 1)
        #expect(spy.measures == 1)
        #expect(spy.records.isEmpty)
    }
}

/// A fixed launch sample and the histogram samples the gate records.
@MainActor
private final class LaunchSpy {
    private(set) var records: [(HistogramID, Duration)] = []
    private(set) var measures = 0
    private let sinceProcessStart: Duration?
    private let temperature: HistogramID.LaunchTemperature

    init(sinceProcessStart: Duration?, temperature: HistogramID.LaunchTemperature) {
        self.sinceProcessStart = sinceProcessStart
        self.temperature = temperature
    }

    var metric: LaunchFirstFrameMetric {
        LaunchFirstFrameMetric(
            measure: { [self] in
                measures += 1
                return sinceProcessStart.map { ($0, temperature) }
            },
            record: { [self] in records.append(($0, $1)) })
    }
}
