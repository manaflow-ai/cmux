@testable import CmuxNextControl
@testable import CmuxNextControlDiagnostics
import CmuxNextMetrics
import CmuxNextTrace
import Testing

/// The watchdog's field histograms (task 055): `main.turn` per turn and `hang.over250.per_hour` per 30 s of active
/// time, recorded into a test's own store from heartbeats driven by hand on an injected clock.
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

    /// One main-thread turn: wake, the person's input when `input` (stamped now), `work`, sleep, then `idle` asleep.
    private static func turn(_ watchdog: MainThreadWatchdog, _ clock: ManualUptime, work: Duration, idle: Duration = .zero,
                             input: Bool = false) {
        watchdog.heartbeat(.afterWaiting)
        if input {
            let now = clock.read()
            watchdog.noteInputDispatch(eventTimestamp: Double(now) / 1_000_000_000, dispatchedNanos: now)
        }
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
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil, "no input, no active time")
    }

    /// Stalls of 250 ms or more (not 249 ms) count in the 30 s of active time they end in, as a rate per hour (each
    /// stall 120): one sample per interval, 0 for an interval with none.
    @MainActor
    @Test func countsStallsOf250MillisecondsPerActiveInterval() throws {
        let clock = ManualUptime()
        let (watchdog, store) = Self.watchdogWithStore(clock: clock)
        // Inputs 11 s apart: the interval closes at the fourth, 33 active seconds in.
        for work: Duration in [.milliseconds(300), .milliseconds(249), .milliseconds(250)] {
            Self.turn(watchdog, clock, work: work, idle: .seconds(11) - work, input: true)
        }
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil, "22 active seconds: the interval is open")
        Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(11) - .milliseconds(1), input: true)
        let first = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(first.count == 1)
        #expect(first.sum == 2 * 120, "the 300 and 250 ms stalls; the 249 ms one is under the edge")
        for _ in 0 ..< 3 { Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(11) - .milliseconds(1), input: true) }
        let second = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(second.count == 2, "a second interval with no stall")
        #expect(second.sum == 2 * 120)
        #expect(second.buckets.contains { $0.index == 0 && $0.count == 1 })
    }

    /// A launch that ends 40 active minutes in, with no quit (a crash, a force quit), still has its stalls in the
    /// store: only the open interval's under 30 s are missing, and a decided quit records those too, once.
    @MainActor
    @Test func aLaunchShorterThanAnHourKeepsItsStalls() throws {
        let clock = ManualUptime()
        let (watchdog, store) = Self.watchdogWithStore(clock: clock)
        // Inputs 10 s apart for 2_410 s: 80 full intervals and 10 s open; stalls in turns 5 to 14 and the last.
        for index in 0 ... 241 {
            let work: Duration = (5 ... 14).contains(index) || index == 241 ? .milliseconds(300) : .milliseconds(1)
            Self.turn(watchdog, clock, work: work, idle: .seconds(10) - work, input: true)
        }
        let atCrash = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(atCrash.count == 80)
        #expect(atCrash.sum == 10 * 120, "the 10 stalls of the closed intervals are in the store")
        watchdog.recordFieldMetricsAtQuit()
        watchdog.recordFieldMetricsAtQuit()
        let atQuit = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(atQuit.count == 81, "the quit records the open interval once")
        #expect(atQuit.sum == 11 * 120, "with the last turn's stall")
    }

    /// The main thread waking every 1.5 s for an hour with no input is not active time, and a stall then (over
    /// 5 minutes after the last input) does not count; nor does the hour between two inputs.
    @MainActor
    @Test func idleWakesWithNoInputAddNoActiveTime() throws {
        let clock = ManualUptime()
        let (watchdog, store) = Self.watchdogWithStore(clock: clock)
        Self.turn(watchdog, clock, work: .milliseconds(1), idle: .milliseconds(1_499), input: true)
        for index in 0 ..< 2_400 {
            let work: Duration = index == 1_000 ? .milliseconds(300) : .milliseconds(1)
            Self.turn(watchdog, clock, work: work, idle: .milliseconds(1_500) - work)
        }
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil, "an hour of wakes is no interval")
        Self.turn(watchdog, clock, work: .milliseconds(1), idle: .seconds(20), input: true)
        Self.turn(watchdog, clock, work: .milliseconds(1), input: true)
        #expect(Self.histogram(.hangOver250PerHour, in: store) == nil, "20 active seconds since the hour away")
        watchdog.recordFieldMetricsAtQuit()
        let atQuit = try #require(Self.histogram(.hangOver250PerHour, in: store))
        #expect(atQuit.count == 1)
        #expect(atQuit.sum == 0, "the stall while the person was away does not count")
        #expect(Self.histogram(.mainTurn, in: store)?.count == 2_403)
    }
}
