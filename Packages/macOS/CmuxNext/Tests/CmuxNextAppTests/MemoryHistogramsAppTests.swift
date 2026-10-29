import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMemory
import Foundation
import Testing

/// The app's feeds of the local memory histograms: the hibernation hooks count
/// discards by kind and wakes, and only the instrumented kinds have a discard histogram.
@MainActor @Suite(.serialized) struct MemoryHistogramsAppTests {
    /// A clock the histograms' hours run on.
    final class HourClock {
        var now: Duration = .zero
    }

    private static func histograms(_ clock: HourClock) -> MemoryHistograms {
        MemoryHistograms(pressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                         discardKinds: MemoryHistograms.hibernationKinds, elapsed: { clock.now })
    }

    /// Each hibernated browser page and each released agent page is one discard of its kind, and a
    /// woken page's time to be back is one wake sample. The kinds with no discard path have no histogram.
    @Test func theHibernationHooksCountDiscardsByKindAndWakes() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        let agentPages = AgentPageHibernation(tabs: { nil }, deadlines: services.mainDeadlines)
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
