@testable import CmuxNextControl
import CmuxNextWakeups
import Foundation
import CmuxNextCompat
import Testing

/// The busy watchdog (plans/cmux-next/idle-wakeups.md) records CPU use that
/// nothing explains, and nothing else.
@Suite(.serialized, .timeLimit(.minutes(1))) struct BusyWatchdogTests {
    /// The production read path must not grow reabstraction thunks in the
    /// stored callback. Invoke on a cooperative thread like DemandTimer does.
    @Test func helperSourceSurvivesFiftyThousandReads() async {
        await Task.detached {
            let watchdog = BusyWatchdog(log: HangLog(), ledger: WakeupLedger(), activity: ExpectedActivity())
            watchdog.setHelperSource { [.init(pid: 42, label: "Chromium tab")] }
            var source = watchdog.helperSource()
            for _ in 0..<50_000 {
                source = watchdog.helperSource()
            }
            let helpers = source()
            #expect(helpers.count == 1)
            #expect(helpers.first?.pid == 42)
            #expect(helpers.first?.label == "Chromium tab")
        }.value
    }

    @Test func helperSourceCanReplaceItselfOutsideTheLock() {
        let watchdog = BusyWatchdog(log: HangLog(), ledger: WakeupLedger(), activity: ExpectedActivity())
        watchdog.setHelperSource {
            watchdog.setHelperSource { [.init(pid: 43, label: "Replacement")] }
            return [.init(pid: 42, label: "Original")]
        }
        #expect(watchdog.helperSource()().first?.pid == 42)
        #expect(watchdog.helperSource()().first?.pid == 43)
    }

    final class Flag: Sendable {
        let value = Atomic(true)
    }

    final class Count: Sendable {
        let value = Atomic(0)
    }

    private func spin(for duration: Duration, while condition: Flag) -> Thread {
        let thread = Thread {
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end, condition.value.load(ordering: .relaxed) {}
        }
        thread.start()
        return thread
    }

    private func settle(_ log: HangLog, window: Duration) async throws {
        try await Task.sleep(for: window + .milliseconds(250))
    }

    /// The shared machine can be heavily loaded, so a spinning thread may get
    /// a small share of a core; the threshold is low accordingly.
    @Test func unexplainedCPURecordsABusyWindow() async throws {
        let log = HangLog()
        let activity = ExpectedActivity()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), windowLeeway: .zero, processThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: activity)
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        let busy = log.records().filter { $0.kind == .busy }
        #expect(busy.count >= 1)
        #expect(busy.first?.details["scope"] == "process")
        #expect(log.summary.busyCount >= 1)
        #expect(log.summary.count == 0)
    }

    /// A busy renderer's record names every tab it serves. This process stands in for
    /// renderer 7: one tab reports it as its main frame's renderer, a same-site tab hosts a frame in it
    /// (client id 7), and a third has another renderer and is not named.
    @Test func aBusyRendererNamesEveryTabItServes() async throws {
        let log = HangLog()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), windowLeeway: .zero, mainThreadThreshold: 100, processThreshold: 100,
                                                         helperThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: ExpectedActivity())
        let me = getpid()
        watchdog.setHelperSource { [.init(pid: me, label: "cef-renderer", rendererClientID: 7)] }
        let directory = TabRendererDirectory()
        directory.update(ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: me, rendererClients: [7]))
        directory.update(ProcessUsage.TabRenderers(tab: "b", title: "Docs 2", pid: nil, rendererClients: [7]))
        directory.update(ProcessUsage.TabRenderers(tab: "c", title: "Other", pid: me &+ 1, rendererClients: [8]))
        watchdog.setTabSource { directory.snapshot() }
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        let helper = try #require(log.records().first { $0.kind == .busy && $0.details["scope"] == "helper" })
        #expect(helper.details["serves"] == "cef-renderer")
        let named = helper.details["tabs"]?.arrayValue?.compactMap { $0["tab"]?.stringValue }
        #expect(named == ["a", "b"])
        #expect(helper.details["tabs"]?.arrayValue?.first?["title"]?.stringValue == "Docs")
    }

    /// A busy helper that is not a tab renderer (GPU, an extension renderer) names no tab, even when a stale
    /// tab pid names it, and the tab source is not read.
    @Test func aBusyHelperThatIsNotATabRendererNamesNoTabs() async throws {
        let log = HangLog()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), windowLeeway: .zero, mainThreadThreshold: 100, processThreshold: 100,
                                                         helperThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: ExpectedActivity())
        let me = getpid()
        let reads = Count()
        watchdog.setHelperSource { [.init(pid: me, label: "cef-gpu")] }
        watchdog.setTabSource {
            reads.value.add(1, ordering: .relaxed)
            return [ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: me, rendererClients: [])]
        }
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        let helper = try #require(log.records().first { $0.kind == .busy && $0.details["scope"] == "helper" })
        #expect(helper.details["serves"] == "cef-gpu")
        #expect(helper.details["tabs"] == nil)
        #expect(reads.value.load(ordering: .relaxed) == 0)
    }

    /// The close of a window must not keep the watch going by itself. Reading the tabs used to hop to the
    /// main actor, which woke the main run loop and counted as the app being awake: an idle app with one
    /// busy renderer then opened a window and wrote a record every window, without end. The tab source
    /// here wakes the watchdog as that hop did; with no other wake there is one window and one record.
    @Test func aBusyRendererWithNoOtherWakeGivesOneWindowAndOneRecord() async throws {
        let log = HangLog()
        let ledger = WakeupLedger()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(200), windowLeeway: .zero, mainThreadThreshold: 100, processThreshold: 100,
                                                         helperThreshold: 0.05, logBusy: false),
                                    log: log, ledger: ledger, activity: ExpectedActivity())
        let me = getpid()
        watchdog.setHelperSource { [.init(pid: me, label: "cef-renderer", rendererClientID: 7)] }
        watchdog.setTabSource {
            watchdog.noteAwake()
            return [ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: me, rendererClients: [7])]
        }
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(800))
        running.value.store(false, ordering: .relaxed)
        let helpers = log.records().filter { $0.kind == .busy && $0.details["scope"] == "helper" }
        #expect(helpers.count == 1)
        #expect(helpers.first?.details["tabs"]?.arrayValue?.compactMap { $0["tab"]?.stringValue } == ["a"])
        #expect(ledger.snapshot().first { $0.owner == "BusyWatchdog.window" }?.count == 1)
    }

    /// Without a tab source a busy helper's record is as before: its kind, no tabs.
    @Test func withoutATabSourceABusyHelperNamesNoTabs() async throws {
        let log = HangLog()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), windowLeeway: .zero, mainThreadThreshold: 100, processThreshold: 100,
                                                         helperThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: ExpectedActivity())
        let me = getpid()
        watchdog.setHelperSource { [.init(pid: me, label: "cef-renderer", rendererClientID: 7)] }
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        let helper = try #require(log.records().first { $0.kind == .busy && $0.details["scope"] == "helper" })
        #expect(helper.details["tabs"] == nil)
    }

    @Test func cpuDuringInputIsExpected() async throws {
        let log = HangLog()
        let activity = ExpectedActivity()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), windowLeeway: .zero, processThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: activity)
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        activity.note(.input)
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        #expect(log.records().allSatisfy { $0.kind != .busy })
    }

    /// Other suites share this process's CPU, so the thresholds here are out
    /// of reach: this checks only that watching stops without a wake.
    @Test func withoutAWakeWatchingStopsAfterOneWindow() async throws {
        let log = HangLog()
        let ledger = WakeupLedger()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(200), windowLeeway: .zero, mainThreadThreshold: 100,
                                                         processThreshold: 100, helperThreshold: 100, logBusy: false),
                                    log: log, ledger: ledger, activity: ExpectedActivity())
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.records().isEmpty)
        // One window, then idle: no further window deadlines.
        #expect(ledger.snapshot().first { $0.owner == "BusyWatchdog.window" }?.count == 1)
    }
}
