import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextMemory
@testable import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The critical memory event's one urgent pass over browser tabs, agent chats and cmux pages
/// (feature `memoryUrgentDiscardRanking`), driven as the app drives it: the coordinator's
/// critical level, then its release slice. Exactly one page goes, the longest hidden unprotected one of
/// any kind, through its own owner only (a tab's discard probe, the page lifecycle's discard, the chat
/// owner's release); the browser's paced pass waits one critical pace interval, and a hide in between
/// discards no due tab. Without the feature the slice runs the browser's own pass as before.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserHibernationUrgentPassTests {
    @Test func theLongestHiddenTabIsTheEventsOneDiscardAndTheOtherDueTabsWait() {
        let rig = Rig(ranks: true)
        defer { rig.close() }
        rig.hideTab("a")
        rig.advance(seconds: 100)
        rig.hideTab("b")
        rig.advance(seconds: 900)  // a hidden 1000 s, b 900 s
        rig.hidePage("p", hiddenFor: .seconds(950))

        rig.kernel.send(.critical)
        #expect(rig.hibernation.probing.isEmpty, "the pressure event's own turn started a tab's discard")
        rig.slices.runAll()

        #expect(rig.hibernation.lastUrgentPass.keys == ["a"])
        #expect(rig.hibernation.lastUrgentPass.discards.first?.kind == .browser)
        #expect(rig.hibernation.probing == ["a"], "not exactly the chosen tab went to its discard probe")
        #expect(rig.lifecycle.state(of: "p") == .hidden, "the page lifecycle discarded too")
        #expect(rig.page.lines.isEmpty)
        #expect(rig.hibernation.nextCheck == HibernationPlanner.criticalPace.interval,
                "the browser's paced pass is not one critical pace interval after the urgent pass")

        // A hide right after the urgent pass replans: the due tab still waits for the interval's end.
        rig.hideTab("c")
        #expect(rig.hibernation.probing == ["a"], "a hide within the urgent interval discarded a due tab")
    }

    @Test func aPageHiddenLongerThanEveryTabIsTheEventsOneDiscard() {
        let rig = Rig(ranks: true)
        defer { rig.close() }
        rig.hideTab("a")
        rig.hideTab("b")
        rig.advance(seconds: 900)
        rig.hidePage("p", hiddenFor: .seconds(1_200))

        rig.kernel.send(.critical)
        rig.slices.runAll()

        #expect(rig.hibernation.lastUrgentPass.keys == ["p"])
        #expect(rig.lifecycle.state(of: "p") == .discarded)
        #expect(rig.page.lines == ["discard"])
        #expect(rig.hibernation.probing.isEmpty, "a browser tab went with the page")
        #expect(rig.hibernation.nextCheck == HibernationPlanner.criticalPace.interval)
    }

    @Test func aChatHiddenLongestIsTheEventsOneDiscard() {
        let rig = Rig(ranks: true)
        defer { rig.close() }
        let chats = ChatOwner([UrgentDiscardRanker.Candidate(key: "chat", kind: .agentPage, hiddenFor: 5_000)])
        let others = rig.hibernation.urgentDiscardOwners
        rig.hibernation.urgentDiscardOwners = { [chats] + others() }
        rig.hideTab("a")
        rig.advance(seconds: 900)
        rig.hidePage("p", hiddenFor: .seconds(1_200))

        rig.kernel.send(.critical)
        rig.slices.runAll()

        #expect(rig.hibernation.lastUrgentPass.keys == ["chat"])
        #expect(chats.discarded == ["chat"])
        #expect(chats.passesHeard == 1)
        #expect(rig.hibernation.probing.isEmpty, "a browser tab went with the chat")
        #expect(rig.lifecycle.state(of: "p") == .hidden, "a page went with the chat")
    }

    /// The default owners are the agent chats' hibernation and the page lifecycle the cache holds.
    @Test func theAgentChatsAndThePageLifecycleAreTheOtherOwners() {
        let rig = Rig(ranks: true)
        defer { rig.close() }
        #expect(rig.hibernation.urgentDiscardOwners().map { ObjectIdentifier($0) } == [ObjectIdentifier(rig.lifecycle)])
        let chats = AgentPageHibernation(tabs: { nil }, deadlines: rig.services.mainDeadlines)
        rig.hibernation.agentPages = chats
        #expect(rig.hibernation.urgentDiscardOwners().map { ObjectIdentifier($0) } == [ObjectIdentifier(chats), ObjectIdentifier(rig.lifecycle)])
        #expect(chats.leavesCriticalEventToUrgentPass && rig.lifecycle.leavesCriticalEventToUrgentPass,
                "the followers were not told the urgent pass takes the critical event")
    }

    /// Feature off: the slice runs the browser's own critical pass (up to `criticalPace.perPass` due tabs),
    /// ranks nothing, and leaves the pages to their own lifecycle.
    @Test func withoutTheFeatureTheSliceRunsTheBrowsersOwnPass() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        rig.hideTab("a")
        rig.hideTab("b")
        rig.advance(seconds: 900)
        rig.hidePage("p", hiddenFor: .seconds(1_200))

        rig.kernel.send(.critical)
        rig.slices.runAll()

        #expect(rig.hibernation.lastUrgentPass.discards.isEmpty)
        #expect(rig.hibernation.probing == ["a", "b"], "the browser's own pass did not take its due tabs")
        #expect(rig.page.lines.isEmpty, "the browser hibernation discarded a page with the feature off")
        #expect(!rig.lifecycle.leavesCriticalEventToUrgentPass)
        #expect(rig.lifecycle.noDiscardBefore == nil)
    }

    // MARK: Rig

    /// An owner of chats that offers fixed candidates and records what the pass asks of it.
    final class ChatOwner: UrgentDiscardOwner {
        let candidates: [UrgentDiscardRanker.Candidate]
        var discarded: [String] = []
        var passesHeard = 0

        init(_ candidates: [UrgentDiscardRanker.Candidate]) {
            self.candidates = candidates
        }

        func urgentCandidates() -> [UrgentDiscardRanker.Candidate] { candidates }
        func urgentDiscard(_ key: String) -> Bool {
            discarded.append(key)
            return true
        }
        func urgentPassDidRun() { passesHeard += 1 }
    }

    /// A cmux page that logs the lifecycle's steps.
    final class PageLog {
        var lines: [String] = []
    }

    struct PageTarget: PageLifecycleTarget {
        let log: PageLog
        var object: AnyObject? { log }
        var lifecycleGroup: String? { "privileged" }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { [] }
        func reportsReasonChanges(to lifecycle: PageLifecycle) {}
        func keepHideSnapshot() {}
        func dropHideSnapshot() {}
        func freeze() -> Bool {
            log.lines.append("freeze")
            return true
        }
        func thaw() { log.lines.append("thaw") }
        func discard() -> Bool {
            log.lines.append("discard")
            return true
        }
    }

    final class TestClock {
        var instant = ContinuousClock.now
    }

    /// App services, a browser hibernation on its own memory coordinator (release slices held until the
    /// test runs them) and a test clock, a page lifecycle on a deadline scheduler whose uptime only the
    /// test moves, and mock browser tabs that can hibernate.
    @MainActor final class Rig {
        let services: AppServices
        let kernel: ManualMemoryPressureSource
        let pressure: MemoryPressureEvents
        let slices: BrowserHibernationPressureTests.HeldSlices
        let coordinator: MemoryCoordinator
        let hibernation: BrowserHibernation
        let lifecycle: PageLifecycle
        let page = PageLog()
        let pane = Pane()
        let engine = MockBrowserEngine()
        let clock: TestClock
        private let uptime: UrgentRigUptime

        init(ranks: Bool) {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let kernel = ManualMemoryPressureSource(), slices = BrowserHibernationPressureTests.HeldSlices()
            let uptime = UrgentRigUptime(), clock = TestClock()
            self.kernel = kernel
            self.slices = slices
            self.uptime = uptime
            self.clock = clock
            pressure = MemoryPressureEvents(source: kernel)
            coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
            let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }),
                                        uptime: { uptime.now }) { _ in UrgentRigWakeUpTimer() }
            lifecycle = PageLifecycle(deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()), queue: queue))
            services.cache.pageLifecycle = lifecycle
            hibernation = BrowserHibernation(cache: services.cache, memory: coordinator, deadlines: services.mainDeadlines)
            services.cache.hibernation = hibernation
            hibernation.now = { clock.instant }
            hibernation.apply(BrowserHibernationSetting(mode: .moderate, freezeSeconds: nil))
            hibernation.ranksUrgentDiscards = ranks
            hibernation.start()
        }

        /// A mock browser tab that can hibernate, shown then hidden now (the test clock's).
        func hideTab(_ key: String) {
            let tab = engine.makeMockTab(BrowserTabConfiguration())
            tab.hibernationRestore = .webKit(Data([1]))
            _ = services.cache.install(tab, for: key)
            services.cache.present(key, by: pane, presence: .visible)
            services.cache.withdraw(key, by: pane)
        }

        /// The cmux page `key`, hidden `hiddenFor` ago on the page lifecycle's clock.
        func hidePage(_ key: String, hiddenFor: Duration) {
            lifecycle.hide(key, page: PageTarget(log: page))
            uptime.now += UInt64(hiddenFor.components.seconds) * 1_000_000_000
        }

        func advance(seconds: Double) { clock.instant += .seconds(seconds) }

        func close() {
            hibernation.stop()
            withExtendedLifetime((services, pressure, coordinator)) {}
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}

/// A timer the queue arms and parks; nothing fires it.
private nonisolated final class UrgentRigWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The page lifecycle's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class UrgentRigUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
