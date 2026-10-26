import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextMemory
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The app's feeds of the local memory histograms (p07-memory-016): the footprint emitter samples
/// once per interval on its own deadline, and the hibernation hooks count discards by kind and
/// wakes. Only the instrumented kinds have a discard histogram.
@MainActor @Suite(.serialized) struct MemoryHistogramsAppTests {
    /// A clock the histograms' hours run on.
    final class HourClock {
        var now: Duration = .zero
    }

    /// The live PID reads the emitter made.
    final class Reads {
        var count = 0
    }

    private static func histograms(_ clock: HourClock) -> MemoryHistograms {
        MemoryHistograms(pressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                         discardKinds: MemoryHistograms.hibernationKinds, elapsed: { clock.now })
    }

    /// One sample per interval with the live WebContent PIDs, none before the interval ends, a
    /// second `start` arms nothing more, and `stop` ends the sampling. The next deadline is armed
    /// only after the sample is recorded, so waiting for it is waiting for the record.
    @Test func theEmitterSamplesOncePerInterval() async throws {
        let clock = ManualClock()
        let histograms = Self.histograms(HourClock())
        let reads = Reads()
        let emitter = MemoryFootprintEmitter(
            histograms: histograms,
            webContentPIDs: {
                reads.count += 1
                return [900]
            },
            sample: { webContent in
                let app = MemoryDiagnosticsProcesses.Row(kind: .app, pid: 1, physFootprintBytes: 300 << 20)
                let pages = webContent.map { MemoryDiagnosticsProcesses.Row(kind: .webkitWebContent, pid: $0, physFootprintBytes: 40 << 20) }
                return MemoryDiagnosticsProcesses(rows: [app] + pages)
            },
            interval: .seconds(3_600),
            timer: DemandTimer(owner: "test.memory-footprints", clock: clock, ledger: WakeupLedger()))
        emitter.start()
        emitter.start()
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "a second start armed a second deadline")

        clock.advance(by: .seconds(1_800))
        #expect(histograms.snapshot().appFootprintMiB.count == 0, "sampled before the interval ended")
        clock.advance(by: .seconds(1_800))
        try await clock.waitForSleeper()
        var snapshot = histograms.snapshot()
        #expect(reads.count == 1)
        #expect(snapshot.appFootprintMiB.count == 1)
        #expect(snapshot.appFootprintMiB.sum == 300)
        #expect(snapshot.rendererFootprintMiB.sum == 40)

        clock.advance(by: .seconds(3_600))
        try await clock.waitForSleeper()
        snapshot = histograms.snapshot()
        #expect(reads.count == 2)
        #expect(snapshot.appFootprintMiB.count == 2)

        emitter.stop()
        #expect(clock.sleeperCount == 0, "stop left the deadline armed")
        clock.advance(by: .seconds(3_600))
        #expect(histograms.snapshot().appFootprintMiB.count == 2)
    }

    /// Each hibernated browser page and each released agent page is one discard of its kind, and a
    /// woken page's time to be back is one wake sample. The kinds with no discard path have no histogram.
    @Test func theHibernationHooksCountDiscardsByKindAndWakes() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry())
        let agentPages = AgentPageHibernation(tabs: { nil })
        let clock = HourClock()
        let histograms = Self.histograms(clock)
        histograms.follow(hibernation, agentPages: agentPages)

        hibernation.onHibernate()
        hibernation.onHibernate()
        agentPages.onRelease()
        hibernation.onWakeMounted(.milliseconds(120))
        clock.now = .seconds(3_600)
        let snapshot = histograms.snapshot()

        #expect(snapshot.discardsPerHour.keys.sorted() == ["agent_page", "browser"])
        #expect(snapshot.discardsPerHour["browser"]?.sum == 2)
        #expect(snapshot.discardsPerHour["agent_page"]?.sum == 1)
        #expect(snapshot.wakeMilliseconds.count == 1)
        #expect(snapshot.wakeMilliseconds.sum == 120)
    }

    /// The app's histograms have a discard histogram for the instrumented kinds only: a kind whose
    /// discards are not counted is absent, never a measured 0.
    @Test func onlyInstrumentedKindsHaveADiscardHistogram() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.memoryHistograms.snapshot().discardsPerHour.keys.sorted() == ["agent_page", "browser"])
    }

    /// A wake's latency is the time from its start to its page being back; a page with no wake started has none.
    @Test func aMountedWakeReturnsItsLatency() {
        var wakes = HibernationWakes()
        let start = ContinuousClock.now
        #expect(wakes.mounted("never-woken", visible: true, at: start) == nil)
        wakes.start("tab", engine: .webkit, snapshot: true, at: start)
        #expect(wakes.mounted("tab", visible: true, at: start + .milliseconds(240)) == .milliseconds(240))
        #expect(wakes.records.last?.mountedMs == 240)
    }
}
