@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The hang monitor's drift tolerance and its lane counts: when the watchdog thread's wait
/// overruns its timeout by more than 100 ms, the monitor blames no scope open then, in either tier, as Chrome's
/// `HangWatcher::Wait` ignores the deadlines open after a `TimedWait` longer than `kWaitDriftTolerance`
/// (base/threading/hang_watcher.cc). Only those scopes, and only the wait: a scope that opens later is watched, and
/// the watchdog's own work between two waits is no drift. Driven on an injected clock, one service call at a time,
/// each scope held open on a thread of its own; the last tests run the real watchdog thread.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangWatchMonitorDriftTests {
    /// The wait overran its timeout by 300 ms: the scope's jank, its hang 2 s later and a longer scope open then
    /// are not reported, and not counted; a scope that opens afterwards is, in both tiers.
    @Test func aLateWaitBlamesNoScopeOpenThen() throws {
        let rig = try Rig()
        rig.fieldMetrics.inputArrived(atNanos: rig.now.value) // the person is active: a hang would count
        var monitor = rig.monitor()
        let late = HeldScope(watch: rig.watch, name: "terminal.feed", deadline: .milliseconds(100))
        let longer = HeldScope(watch: rig.watch, name: "lane.files", deadline: .seconds(1))
        let parked = monitor.service()  // mutating: #require's call form would make `monitor` a let
        let wait = try #require(parked, "an open scope parks the monitor")
        #expect(wait == 100_000_000, "the monitor sleeps to the first budget")

        rig.now.add(wait + 300_000_000) // the watchdog thread runs 300 ms after its wait's timeout
        _ = monitor.service(waitOverrunNanos: 300_000_000)
        #expect(monitor.lateWakes == 1)
        drive(&monitor, rig.now, for: 4_000_000_000) // on time, past both scopes' hang tiers
        #expect(rig.janks.records().isEmpty, "a late monitor blamed a scope with a jank")
        #expect(rig.hangs.records().isEmpty, "a late monitor blamed a scope with a hang")
        late.close()
        longer.close()

        let after = HeldScope(watch: rig.watch, name: "terminal.feed", deadline: .milliseconds(100))
        drive(&monitor, rig.now, for: 2_500_000_000)
        #expect(rig.janks.records().compactMap { $0.details["scope"] } == [JSONValue.string("terminal.feed")])
        #expect(rig.hangs.records().count == 1, "a scope opened after the late wake is watched again")
        after.close()
        #expect(monitor.lateWakes == 1, "the on-time wakes are not late")

        rig.fieldMetrics.recordOpenInterval()
        let terminal = try #require(rig.histogram(.hangThreadHung(.terminalOutput)))
        #expect(terminal.count == 1)
        #expect(terminal.sum == 120, "one hang in the interval, as a rate per hour; the ignored ones not counted")
        #expect(rig.histogram(.hangThreadHung(.backgroundWork)) == nil, "the ignored longer scope did not count")
    }

    /// A late wait while a 1 s scope is open, then a 100 ms scope opens 200 ms later on another lane while the
    /// first is still open: the new scope's jank and hang are reported; the older scope stays silent.
    @Test func aShortScopeOpenedAfterALateWaitIsWatchedWhileAnOlderLongScopeRuns() throws {
        let rig = try Rig()
        var monitor = rig.monitor()
        let older = HeldScope(watch: rig.watch, name: "lane.files", deadline: .seconds(1))
        let parked = monitor.service()  // mutating: #require's call form would make `monitor` a let
        let wait = try #require(parked)
        #expect(wait == 1_000_000_000)
        rig.now.add(400_000_000) // a 400 ms wait for a 100 ms timeout: 300 ms over
        _ = monitor.service(waitOverrunNanos: 300_000_000)
        #expect(monitor.lateWakes == 1)

        rig.now.add(200_000_000)
        let newer = HeldScope(watch: rig.watch, name: "terminal.feed", deadline: .milliseconds(100))
        drive(&monitor, rig.now, for: 3_000_000_000) // past the older scope's hang tier too
        #expect(rig.janks.records().compactMap { $0.details["scope"] } == [JSONValue.string("terminal.feed")],
                "the newer scope's jank is reported, the older scope's is not")
        #expect(rig.hangs.records().compactMap { $0.details["scope"] } == [JSONValue.string("terminal.feed")],
                "the newer scope's hang is reported, the older scope's is not")
        newer.close()
        older.close()
    }

    /// The watchdog spends 500 ms on its own work between two waits, each wait on time: no drift, the scope is
    /// reported.
    @Test func theWatchdogsOwnWorkBetweenWaitsIsNoDrift() throws {
        let rig = try Rig()
        var monitor = rig.monitor()
        let scope = HeldScope(watch: rig.watch, name: "daemon.line", deadline: .milliseconds(100))
        let parked = monitor.service()  // mutating: #require's call form would make `monitor` a let
        let wait = try #require(parked)
        rig.now.add(wait + 500_000_000) // the wait ended on time, then the thread reported a main-thread hang
        _ = monitor.service(waitOverrunNanos: 0)
        #expect(monitor.lateWakes == 0)
        #expect(rig.janks.records().count == 1)
        drive(&monitor, rig.now, for: 2_000_000_000)
        #expect(rig.hangs.records().count == 1)
        scope.close()
    }

    /// A wait 50 ms past its timeout is within the tolerance: the scope is reported.
    @Test func aWaitWithinTheToleranceStillReports() throws {
        let rig = try Rig()
        var monitor = rig.monitor()
        let scope = HeldScope(watch: rig.watch, name: "daemon.line", deadline: .milliseconds(100))
        let parked = monitor.service()  // mutating: #require's call form would make `monitor` a let
        let wait = try #require(parked)
        rig.now.add(wait + 50_000_000)
        _ = monitor.service(waitOverrunNanos: 50_000_000)
        #expect(monitor.lateWakes == 0)
        #expect(rig.janks.records().count == 1)
        scope.close()
    }

    /// A parked monitor's wait has no timeout, so it never overruns: the scope that wakes it, however long after,
    /// is reported in both tiers.
    @Test func aParkedMonitorIsNeverLate() throws {
        let rig = try Rig()
        var monitor = rig.monitor()
        #expect(monitor.service() == nil, "nothing open: parked")
        rig.now.add(60_000_000_000)
        let scope = HeldScope(watch: rig.watch, name: "daemon.line", deadline: .milliseconds(100))
        drive(&monitor, rig.now, for: 2_500_000_000)
        #expect(monitor.lateWakes == 0)
        #expect(rig.janks.records().count == 1)
        #expect(rig.hangs.records().count == 1)
        scope.close()
    }

    /// Each registration counts in its lane: the names lanes register with, then the kind, then `other`.
    @Test func eachRegistrationCountsInItsLane() {
        #expect(HangMonitor.lane(name: "daemon.line", kind: .lane) == .daemonReader)
        #expect(HangMonitor.lane(name: "terminal.feed", kind: .lane) == .terminalOutput)
        #expect(HangMonitor.lane(name: "lane.files", kind: .lane) == .backgroundWork)
        #expect(HangMonitor.lane(name: "lane.system", kind: .lane) == .backgroundWork)
        #expect(HangMonitor.lane(name: "lane.cpu", kind: .lane) == .backgroundWork)
        #expect(HangMonitor.lane(name: "control.accept", kind: .control) == .control)
        #expect(HangMonitor.lane(name: "test.unknown", kind: .io) == .other)
        #expect(HistogramID.HangLane.allCases.count <= MainThreadFieldMetrics.laneCapacity, "a lane past the counts' capacity")
    }

    #if DEBUG
    /// Detection on the real watchdog thread: a scope's hang is reported within its hang deadline (budget plus
    /// `hangAfterBudget`) plus one minimum deadline plus 50 ms.
    @Test func aHangIsSeenWithinItsDeadlinePlusOneMinimumDeadline() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        let watch = HangWatch(minimumDeadline: .milliseconds(100), hangAfterBudget: .milliseconds(300))
        let reportedAt = Counter(0)
        let reported = DispatchSemaphore(value: 0)
        var source = HangMonitor.Source(watch: watch, crashKeys: nil)
        source.afterHangForTesting = { _ in
            reportedAt.add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            reported.signal()
        }
        watchdog.attach(source)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.name = "hang-watch-drift-test-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        defer { watchdog.stop() }
        let opened = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let scope = HeldScope(watch: watch, name: "terminal.feed", deadline: .milliseconds(100))
        let seen = reported.wait(timeout: .now() + 5) == .success // a wall-clock bound turns a missed hang into a failure
        scope.close()
        try #require(seen, "no hang reported")
        let latency = reportedAt.value - opened
        let bound: UInt64 = 100_000_000 + 300_000_000 + 100_000_000 + 50_000_000 // budget + hang tier + period + 50 ms
        #expect(latency <= bound, "seen \(latency / 1_000_000) ms after the open")
    }

    /// On the real watchdog thread: the main thread hangs, and the watchdog's own hang report (its `onHang` sink)
    /// takes 500 ms, past a lane scope's hang deadline. The wait after it is on time, so the lane's hang is still
    /// reported: the report's time is not counted as drift.
    @Test func aSlowMainThreadHangReportDoesNotSilenceTheLanes() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangThreshold: .milliseconds(200), hangAssertThreshold: nil))
        let watch = HangWatch(minimumDeadline: .milliseconds(100), hangAfterBudget: .milliseconds(300))
        let laneHung = DispatchSemaphore(value: 0)
        let mainHangs = Counter(0)
        var source = HangMonitor.Source(watch: watch, crashKeys: nil)
        source.afterHangForTesting = { _ in laneHung.signal() }
        watchdog.attach(source)
        watchdog.onHang = { _ in
            mainHangs.add(1)
            spin(for: .milliseconds(500)) // the report's own work, past the lane's hang deadline
        }
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.name = "hang-watch-drift-test-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        defer { watchdog.stop() }
        watchdog.heartbeat(.afterWaiting) // the main thread wakes and beats no more: a main hang after 200 ms
        let scope = HeldScope(watch: watch, name: "terminal.feed", deadline: .milliseconds(100))
        let seen = laneHung.wait(timeout: .now() + 5) == .success // a wall-clock bound turns a silenced hang into a failure
        scope.close()
        #expect(mainHangs.value == 1, "the main thread's hang was reported")
        try #require(seen, "the lane's hang was silenced by the watchdog's own report")
        #expect(watchdog.threadJanks.records().count == 1)
    }

    /// Section E's watcher rule on the real watchdog thread, at a 1 s minimum deadline: a lane that opens and
    /// closes short scopes back to back for 5 s wakes the watchdog thread once per second (each scan), plus two
    /// for the first open (its user event, then its 16 ms deadline); never once per scope. The app's slot table
    /// keeps a 100 ms minimum deadline (a 150 ms stall on a 100 ms budget must be seen, p02-threads RUN-8), so
    /// there a burst scans about 10 times a second.
    @Test func aBurstWakesTheWatchdogAtMostOncePerMinimumDeadline() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        let watch = HangWatch(minimumDeadline: .seconds(1))
        watchdog.attach(HangMonitor.Source(watch: watch, crashKeys: nil))
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.name = "hang-watch-drift-test-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        defer { watchdog.stop() }
        spin(for: .milliseconds(200)) // the attach's own wake
        let before = watchdog.watchdogWakes.load(ordering: .relaxed)
        let opened = Counter(0)
        let finished = DispatchSemaphore(value: 0)
        let feed = Thread {
            let lane = watch.registerLane("test.burst")
            let began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began < 5_000_000_000 {
                let scope = watch.watch(lane, deadline: .milliseconds(16))
                spin(for: .microseconds(200))
                scope.close()
                opened.add(1)
            }
            watch.unregister(lane)
            finished.signal()
        }
        feed.name = "hang-watch-drift-test-burst"
        feed.qualityOfService = .userInitiated
        feed.start()
        let done = finished.wait(timeout: .now() + 20) == .success
        try #require(done, "the burst did not finish")
        let wakes = watchdog.watchdogWakes.load(ordering: .relaxed) - before
        #expect(opened.value > 5_000)
        #expect(wakes <= 5 + 2, "\(wakes) watchdog wakes for \(opened.value) scopes in 5 s at a 1 s minimum deadline")
        #expect(watch.wakeRequests < 5, "\(watch.wakeRequests) opens woke the monitor")
    }
    #endif
}

/// A slot table on a clock the test moves, its monitor's logs and a field-metrics store.
private struct Rig {
    let now = Counter(1_000_000_000)
    let watch: HangWatch
    let hangs = HangLog(capacity: 8), janks = HangLog(capacity: 8)
    let store: MetricsStore
    let fieldMetrics: MainThreadFieldMetrics

    init() throws {
        let clock = self.now
        watch = HangWatch(clock: TraceClock(reader: .init(uptimeNanos: { clock.value }, continuousNow: { ContinuousClock.now })))
        let attached = watch.attachMonitor(wake: {})
        try #require(attached)
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        store = MetricsStore(role: .app, profile: profile, pid: 4243,
                             catalog: [HistogramID.hangOver250PerHour] + HistogramID.HangLane.allCases.map(HistogramID.hangThreadHung))
        try #require(store.attach(to: runtime))
        fieldMetrics = MainThreadFieldMetrics(metrics: Metrics(runtime: runtime))
    }

    func monitor() -> HangMonitor {
        HangMonitor(source: HangMonitor.Source(watch: watch, crashKeys: nil), log: hangs, janks: janks, logger: nil,
                    fieldMetrics: fieldMetrics, intervalNanos: 0, deliver: { _ in })
    }

    func histogram(_ id: HistogramID) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }
}

/// Calls the monitor each time it asked to be called, moving the clock exactly that far (never late), for `total` ns.
private func drive(_ monitor: inout HangMonitor, _ now: Counter, for total: UInt64) {
    var elapsed: UInt64 = 0
    while elapsed < total {
        let step = min(max(monitor.service() ?? total - elapsed, 1), total - elapsed)
        now.add(step)
        elapsed += step
    }
    _ = monitor.service()
}

/// A scope opened on a thread of its own, held until ``close()``: the monitor samples a live thread.
private final class HeldScope: Sendable {
    private let opened = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let closed = DispatchSemaphore(value: 0)

    init(watch: HangWatch, name: StaticString, deadline: Duration) {
        let (opened, release, closed) = (opened, release, closed)
        let thread = Thread {
            let registration = watch.registerLane(name)
            let scope = watch.watch(registration, deadline: deadline)
            opened.signal()
            release.wait()
            scope.close()
            watch.unregister(registration)
            closed.signal()
        }
        thread.name = "hang-watch-drift-test-scope"
        thread.qualityOfService = .userInitiated
        thread.start()
        opened.wait()
    }

    /// Closes the scope and returns once it is closed.
    func close() {
        release.signal()
        closed.wait()
    }
}

/// A number the test moves and the clock reads on another thread.
private final class Counter: Sendable {
    private let word: Atomic<UInt64>

    init(_ value: UInt64) {
        word = Atomic(value)
    }

    var value: UInt64 { word.load(ordering: .relaxed) }

    func add(_ amount: UInt64) {
        _ = word.add(amount, ordering: .relaxed)
    }
}
