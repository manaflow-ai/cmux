@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The hang monitor's drift tolerance and its lane counts (p09-observability-067): a monitor that wakes more than
/// 100 ms after the time it asked for blames no scope open then, in either tier, as Chrome's `HangWatcher::Wait`
/// moves `deadline_ignore_threshold_` past a wait longer than `kWaitDriftTolerance` (base/threading/hang_watcher.cc).
/// Driven on an injected clock, one service call at a time, each scope held open on a thread of its own.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangWatchMonitorDriftTests {
    /// The monitor wakes 300 ms after the 100 ms budget it slept to: the scope's jank, its hang 2 s later and a
    /// longer scope open then are not reported, and not counted; a scope that opens afterwards is, in both tiers.
    @Test func aLateMonitorBlamesNoScopeOpenWhenItWoke() throws {
        let rig = try Rig()
        rig.fieldMetrics.inputArrived(atNanos: rig.now.value) // the person is active: a hang would count
        var monitor = rig.monitor()
        let late = HeldScope(watch: rig.watch, name: "terminal.feed", deadline: .milliseconds(100))
        let longer = HeldScope(watch: rig.watch, name: "lane.files", deadline: .seconds(1))
        let wait = try #require(monitor.service(), "an open scope parks the monitor")
        #expect(wait == 100_000_000, "the monitor sleeps to the first budget")

        rig.now.add(wait + 300_000_000) // the watchdog thread runs 300 ms after it asked to
        _ = monitor.service()
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

    /// A wake 50 ms late is within the tolerance: the scope is reported.
    @Test func aWakeWithinTheToleranceStillReports() throws {
        let rig = try Rig()
        var monitor = rig.monitor()
        let scope = HeldScope(watch: rig.watch, name: "daemon.line", deadline: .milliseconds(100))
        let wait = try #require(monitor.service())
        rig.now.add(wait + 50_000_000)
        _ = monitor.service()
        #expect(monitor.lateWakes == 0)
        #expect(rig.janks.records().count == 1)
        scope.close()
    }

    /// A parked monitor asked for no time: the scope that wakes it, however long after, finds it on time.
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
                    fieldMetrics: fieldMetrics)
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
