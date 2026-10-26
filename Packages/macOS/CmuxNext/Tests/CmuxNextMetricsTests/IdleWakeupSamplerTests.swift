import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Testing

/// `idle.wakeups.*` (p09-observability task 059): periods open at resign-active and close at become-active, the person's
/// input or a report trigger, over a fake provider of the counters.
@MainActor
@Suite("Idle wakeups")
struct IdleWakeupSamplerTests {
    /// The counters the fake provider hands out, and how often it was read.
    @MainActor
    final class FakeCounters {
        var uptimeNanos: UInt64 = 1_000_000_000
        var mainWakes: UInt64? = 100
        var app: IdleWakeupSampler.Wakeups? = .init(pid: 10, interrupt: 1_000, packageIdle: 400)
        var daemon: IdleWakeupSampler.Wakeups? = .init(pid: 20, interrupt: 5_000, packageIdle: 900)
        var reads = 0

        var sources: IdleWakeupSampler.Sources {
            IdleWakeupSampler.Sources(uptimeNanos: { self.reads += 1; return self.uptimeNanos }, mainRunLoopWakes: { self.mainWakes },
                                      appWakeups: { self.app }, daemonWakeups: { self.daemon })
        }

        /// Moves the clock and every counter on: `seconds` of idle with these many wakeups.
        func advance(seconds: UInt64, mainWakes main: UInt64 = 0, app appWakes: UInt64 = 0, daemon daemonWakes: UInt64 = 0) {
            uptimeNanos += seconds * 1_000_000_000
            mainWakes = mainWakes.map { $0 + main }
            app?.interrupt += appWakes
            app?.packageIdle += appWakes / 2
            daemon?.interrupt += daemonWakes
        }
    }

    private static let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                                hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16),
                                                buildUUID: Array(16 ..< 32), buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))

    private let counters: FakeCounters
    private let store: MetricsStore
    private let sampler: IdleWakeupSampler

    init() {
        let counters = FakeCounters()
        self.counters = counters
        let runtime = TraceRuntime(role: .app)
        store = MetricsStore(role: .app, profile: Self.profile, pid: 4242)
        #expect(store.attach(to: runtime))
        sampler = IdleWakeupSampler(sources: counters.sources, metrics: Metrics(runtime: runtime))
    }

    /// The sample count and sum of `source`'s histogram so far.
    private func samples(_ source: HistogramID.WakeupSource) -> [UInt64] {
        guard let histogram = store.delta().histograms.first(where: { $0.name == HistogramID.idleWakeups(source).name }) else { return [0, 0] }
        return [histogram.count, histogram.sum]
    }

    @Test("An inactive period with no input records wakeups per minute for the app's main thread, the app and the daemon")
    func inactivePeriodRecordsRatesPerMinute() {
        sampler.appResignedActive()
        counters.advance(seconds: 120, mainWakes: 30, app: 240, daemon: 60)
        sampler.appBecameActive()

        #expect(samples(.appMain) == [1, 15])
        #expect(samples(.appTotal) == [1, 120])
        #expect(samples(.daemon) == [1, 30])
        #expect(sampler.lastPeriod == IdleWakeupSampler.Period(
            nanos: 120_000_000_000, mainRunLoopWakes: 30, app: .init(pid: 10, interrupt: 240, packageIdle: 120),
            daemon: .init(pid: 20, interrupt: 60, packageIdle: 0)))
        #expect(!sampler.isMeasuring)
    }

    @Test("Input just before become-active, after minutes of idle, ends the period at the input and still records it")
    func inputEndsThePeriodAtTheInput() {
        sampler.appResignedActive()
        counters.advance(seconds: 300, mainWakes: 10, app: 300, daemon: 10)
        sampler.inputArrived()  // the pointer crosses a cmux terminal on the way to its click
        counters.advance(seconds: 1, mainWakes: 500, app: 500, daemon: 500)  // hover work after the input
        sampler.appBecameActive()

        #expect(samples(.appTotal) == [1, 60])
        #expect(samples(.appMain) == [1, 2])
        #expect(samples(.daemon) == [1, 2])
        #expect(sampler.periodsEndedByInput == 1)
        #expect(sampler.lastPeriod?.nanos == 300_000_000_000)
        #expect(!sampler.isMeasuring)
    }

    @Test("Input in a period under a minute records nothing and the next period opens at the input")
    func inputInAShortPeriodRestartsAtTheInput() {
        sampler.appResignedActive()
        counters.advance(seconds: 30, app: 3_000)
        sampler.inputArrived()  // a pointer passing over an inactive window
        #expect(store.delta().isEmpty)
        #expect(sampler.isMeasuring)
        counters.advance(seconds: 90, app: 90)
        sampler.appBecameActive()

        #expect(samples(.appTotal) == [1, 60])
        #expect(sampler.lastPeriod?.nanos == 90_000_000_000)
        #expect(sampler.periodsEndedByInput == 0)
    }

    @Test("A period under a minute records nothing")
    func shortPeriodRecordsNothing() {
        sampler.appResignedActive()
        counters.advance(seconds: 59, mainWakes: 10, app: 10, daemon: 10)
        sampler.appBecameActive()

        #expect(store.delta().isEmpty)
        #expect(sampler.periodsEndedByInput == 0)
    }

    @Test("A report trigger records the period so far and opens the next one")
    func reportTriggerSplitsThePeriod() {
        sampler.appResignedActive()
        counters.advance(seconds: 60, app: 60)
        sampler.reportTriggered()
        #expect(sampler.isMeasuring)
        counters.advance(seconds: 120, app: 480)
        sampler.appBecameActive()

        // 60 per minute, then 240 per minute.
        #expect(samples(.appTotal) == [2, 300])
        #expect(sampler.lastPeriod?.nanos == 120_000_000_000)
    }

    @Test("Counter growth after a report trigger (a quit's own work, the daemon's stop) is not in the period it recorded")
    func quitWorkAfterTheReportTriggerIsNotInThePeriod() {
        sampler.appResignedActive()
        counters.advance(seconds: 120, mainWakes: 30, app: 240, daemon: 60)
        sampler.reportTriggered()
        let recorded = [samples(.appMain), samples(.appTotal), samples(.daemon)]
        counters.advance(seconds: 2, mainWakes: 9_000, app: 9_000, daemon: 9_000)  // snapshot saves, session ends
        counters.daemon = nil  // the daemon stopped

        #expect(recorded == [[1, 15], [1, 120], [1, 30]])
        #expect([samples(.appMain), samples(.appTotal), samples(.daemon)] == recorded)
        #expect(sampler.lastPeriod == IdleWakeupSampler.Period(
            nanos: 120_000_000_000, mainRunLoopWakes: 30, app: .init(pid: 10, interrupt: 240, packageIdle: 120),
            daemon: .init(pid: 20, interrupt: 60, packageIdle: 0)))
    }

    @Test("A report trigger in a period under a minute keeps it open")
    func earlyReportTriggerKeepsThePeriod() {
        sampler.appResignedActive()
        counters.advance(seconds: 30, app: 30)
        sampler.reportTriggered()
        #expect(store.delta().isEmpty)
        counters.advance(seconds: 60, app: 60)
        sampler.appBecameActive()

        #expect(samples(.appTotal) == [1, 60])
        #expect(sampler.lastPeriod?.nanos == 90_000_000_000)
    }

    @Test("While the app is active nothing is read or recorded")
    func activeAppReadsNothing() {
        sampler.appBecameActive()
        sampler.reportTriggered()
        counters.advance(seconds: 600, mainWakes: 100, app: 100, daemon: 100)
        sampler.inputArrived()
        sampler.appBecameActive()

        #expect(counters.reads == 0)
        #expect(store.delta().isEmpty)
    }

    @Test("A second resign keeps the period that is open")
    func secondResignKeepsTheOpenPeriod() {
        sampler.appResignedActive()
        counters.advance(seconds: 60, app: 60)
        sampler.appResignedActive()
        counters.advance(seconds: 60, app: 60)
        sampler.appBecameActive()

        #expect(counters.reads == 2)
        #expect(sampler.lastPeriod?.nanos == 120_000_000_000)
    }

    @Test("A daemon that restarted in the period, or a counter that could not be read, records no sample for it")
    func changedOrMissingCountersRecordNoSample() {
        sampler.appResignedActive()
        counters.advance(seconds: 60, mainWakes: 6, app: 60, daemon: 60)
        counters.daemon = .init(pid: 21, interrupt: 3, packageIdle: 0)
        counters.mainWakes = nil
        sampler.appBecameActive()

        #expect(samples(.appTotal) == [1, 60])
        #expect(samples(.appMain) == [0, 0])
        #expect(samples(.daemon) == [0, 0])
    }

    @Test("The rate per minute rounds down and never overflows")
    func perMinuteRate() {
        let minute = IdleWakeupSampler.Period(nanos: 90_000_000_000, mainRunLoopWakes: nil, app: nil, daemon: nil)
        #expect(minute.perMinute(0) == 0)
        #expect(minute.perMinute(4) == 2)
        #expect(minute.perMinute(.max) == .max)
    }

    @Test("The live reader reads this process's wakeup counters")
    func liveReaderReadsThisProcess() throws {
        let wakeups = try #require(IdleWakeupSampler.wakeups(of: getpid()))
        #expect(wakeups.pid == getpid())
    }
}
