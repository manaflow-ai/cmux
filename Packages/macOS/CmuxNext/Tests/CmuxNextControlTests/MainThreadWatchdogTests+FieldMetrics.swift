@testable import CmuxNextControl
import CmuxNextMetrics
import CmuxNextTrace
import Testing

/// The watchdog's field histograms (task 055): `main.turn` per turn and `hang.over250.per_hour` per active hour,
/// recorded into a test's own store from heartbeats driven by hand on an injected clock.
extension MainThreadWatchdogTests {
    /// A watchdog on `clock` whose field histograms go to a fresh store, and that store.
    private static func watchdogWithStore(clock: ManualUptime) -> (MainThreadWatchdog, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242, catalog: [.mainTurn, .hangOver250PerHour])
        #expect(store.attach(to: runtime))
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read,
                                          fieldMetrics: MainThreadFieldMetrics(metrics: Metrics(runtime: runtime)))
        return (watchdog, store)
    }

    private static func histogram(_ id: HistogramID, in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    /// One main-thread turn: wake, `work`, sleep, then `idle` asleep.
    private static func turn(_ watchdog: MainThreadWatchdog, _ clock: ManualUptime, work: Duration, idle: Duration = .zero) {
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: work)
        watchdog.heartbeat(.beforeWaiting)
        clock.advance(by: idle)
    }

    /// Each turn's busy time, wake to sleep across its beats, is one `main.turn` sample in us; time asleep is not.
    @MainActor
    @Test func recordsEachTurnsBusyTimeAsMainTurn() throws {
        let clock = ManualUptime()
        let (watchdog, store) = Self.watchdogWithStore(clock: clock)
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: .microseconds(400))
        watchdog.heartbeat(.beforeTimers)
        clock.advance(by: .milliseconds(2))
        watchdog.heartbeat(.beforeWaiting)
        clock.advance(by: .seconds(30))
        Self.turn(watchdog, clock, work: .microseconds(300))
        let turns = try #require(Self.histogram(.mainTurn, in: store))
        #expect(turns.count == 2)
        #expect(turns.sum == 2_700)
        let layout = HistogramID.mainTurn.layout
        let expected = [layout.bucketIndex(of: 300), layout.bucketIndex(of: 2_400)].compactMap { $0 }.sorted()
        #expect(turns.buckets.map(\.index) == expected)
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil, "no active hour yet")
    }

    /// Stalls of 250 ms or more (not 249 ms) count toward the active hour they end in: one sample per full active
    /// hour, 0 for an hour with none. An idle gap counts at most 5 minutes of active time.
    @MainActor
    @Test func countsStallsOf250MillisecondsPerActiveHour() throws {
        let clock = ManualUptime()
        let (watchdog, store) = Self.watchdogWithStore(clock: clock)
        Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(600))
        // 1 ms + 11 turns of 5 capped idle minutes plus their work: under an hour.
        let works: [Duration] = [.milliseconds(300), .milliseconds(249), .milliseconds(250)] + Array(repeating: .milliseconds(1), count: 8)
        for work in works { Self.turn(watchdog, clock, work: work, idle: .seconds(600)) }
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil, "\(works.count) turns stay under an active hour")
        Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(600))
        let firstHour = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(firstHour.count == 1)
        #expect(firstHour.sum == 2, "the 300 and 250 ms stalls; the 249 ms one is under the edge")
        for _ in 0 ..< 12 { Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(600)) }
        let twoHours = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(twoHours.count == 2, "a second active hour with no stall")
        #expect(twoHours.sum == 2)
        #expect(twoHours.buckets.contains { $0.index == 0 && $0.count == 1 })
    }

    /// A launch left idle for hours adds only the capped gap to active time: no hour sample.
    @MainActor
    @Test func aLongIdleGapAddsOnlyFiveActiveMinutes() {
        let clock = ManualUptime()
        let (watchdog, store) = Self.watchdogWithStore(clock: clock)
        Self.turn(watchdog, clock, work: .milliseconds(300), idle: .seconds(3 * 3_600))
        Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(3 * 3_600))
        Self.turn(watchdog, clock, work: .milliseconds(1))
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil)
        #expect(Self.histogram(.mainTurn, in: store)?.count == 3)
    }
}
