import CmuxNextCompat
@testable import CmuxNextBrowser
@testable import CmuxNextWakeups
import Foundation
import Testing

/// Keyed waits on a page (p06-scheduler-028): `page.when(phase:)` and `page.whenPrompt(kind:)` read
/// their condition only when the page's phase changes or it adds a prompt, resume once on the
/// transition, and resume with nil on their deadline, on cancel or when the page closes. The
/// deadlines are entries on a MainWakeUpQueue whose uptime the test moves.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PageWaitersTests {
    private static let url = URL(string: "https://example.com/")!

    private func page() -> MockBrowserTab {
        MockBrowserEngine(completesNavigationsImmediately: false).makeMockTab(BrowserTabConfiguration())
    }

    @Test func aPhaseWaiterReadsNothingOnTitleChangesAndResumesOnceOnItsTransition() async {
        let tab = page()
        let finished = Task { await tab.when(phase: .finished) }
        await tab.pageWaiters.untilPending(1)
        let before = tab.pageWaiters.evaluations

        let navigation = tab.makeNavigationID()
        tab.simulate(.started(navigation, url: Self.url))
        tab.simulate(.committed(navigation, url: Self.url))
        let afterCommit = tab.pageWaiters.evaluations
        for index in 0..<1_000 { tab.simulate(.titleChanged("title \(index)")) }
        for tick in 1...9 { tab.simulate(.progress(Double(tick) / 10)) }
        #expect(tab.pageWaiters.evaluations == afterCommit, "title and progress changes read \(tab.pageWaiters.evaluations - afterCommit) conditions")
        #expect(tab.pageWaiters.pendingCount == 1)

        tab.simulate(.finished(navigation))
        #expect(tab.pageWaiters.pendingCount == 0, "the finish resumed the waiter in its setter")
        #expect(tab.pageWaiters.evaluations - before == 3, "one read per phase change: provisional, committed, finished")
        #expect(await finished.value)

        let again = tab.makeNavigationID()
        tab.simulate(.started(again, url: Self.url))
        tab.simulate(.finished(again))
        #expect(tab.pageWaiters.evaluations - before == 3, "a resumed waiter is read no more")
    }

    @Test func aPhaseThatAlreadyHoldsReturnsAtOnce() async {
        let tab = page()
        #expect(await tab.when(phase: .idle))
        #expect(await tab.when(phase: { $0 == .idle }) == .idle)
        #expect(tab.pageWaiters.pendingCount == 0)
    }

    @Test func aPromptWaiterReadsOnlyAddedPromptsAndResumesWhenThePageAsks() async throws {
        let tab = page()
        let asks = Task { await tab.whenPrompt(kind: { $0.isBeforeUnload }) }
        await tab.pageWaiters.untilPending(1)
        let before = tab.pageWaiters.evaluations

        for index in 0..<100 { tab.simulate(.titleChanged("title \(index)")) }
        let navigation = tab.makeNavigationID()
        tab.simulate(.started(navigation, url: Self.url))
        #expect(tab.pageWaiters.evaluations == before, "state changes read a prompt waiter")

        var alertAnswered = false
        tab.enqueuePrompt(.alert(message: "hi"), origin: "https://example.com") { _ in alertAnswered = true }
        #expect(tab.pageWaiters.evaluations - before == 1)
        #expect(tab.pageWaiters.pendingCount == 1, "an alert is not the beforeunload question")

        tab.enqueuePrompt(.beforeUnload(isReload: false), origin: "https://example.com") { _ in }
        #expect(tab.pageWaiters.pendingCount == 0)
        #expect(tab.pageWaiters.evaluations - before == 2)
        let prompt = try #require(await asks.value)
        #expect(prompt.kind == .beforeUnload(isReload: false))

        tab.pendingPrompts.first?.respond(.accept)
        #expect(alertAnswered)
        #expect(tab.pageWaiters.evaluations - before == 2, "a removed prompt reads nothing")
    }

    @Test func aWaitResumesWithNilOnItsDeadlineAndDropsIt() async {
        let rig = DeadlineRig()
        let tab = page()
        let deadline = PageWaiters.Deadline(after: .seconds(1), on: AlignedWakeups(queue: rig.queue))
        let finished = Task { await tab.when(phase: .finished, deadline: deadline) }
        await tab.pageWaiters.untilPending(1)
        #expect(rig.queue.count == 1)

        rig.advance(by: .seconds(2))
        #expect(await finished.value == false)
        #expect(tab.pageWaiters.pendingCount == 0)
        #expect(rig.queue.count == 0)
    }

    @Test func aResumeCancelsItsDeadline() async {
        let rig = DeadlineRig()
        let tab = page()
        let deadline = PageWaiters.Deadline(after: .seconds(60), on: AlignedWakeups(queue: rig.queue))
        let asks = Task { await tab.whenPrompt(kind: { $0.isBeforeUnload }, deadline: deadline) }
        await tab.pageWaiters.untilPending(1)

        tab.enqueuePrompt(.beforeUnload(isReload: true), origin: "https://example.com") { _ in }
        #expect(await asks.value != nil)
        #expect(rig.queue.count == 0, "the resume cancelled its deadline")
    }

    @Test func aCancelledWaitResumesWithNil() async {
        let tab = page()
        let finished = Task { await tab.when(phase: .finished) }
        await tab.pageWaiters.untilPending(1)
        finished.cancel()
        #expect(await finished.value == false)
        #expect(tab.pageWaiters.pendingCount == 0)
    }

    @Test func closingThePageEndsItsWaitsAndLaterOnes() async {
        let tab = page()
        let finished = Task { await tab.when(phase: .finished) }
        let asks = Task { await tab.whenPrompt(kind: { $0.isBeforeUnload }) }
        await tab.pageWaiters.untilPending(2)

        tab.close()
        #expect(await finished.value == false)
        #expect(await asks.value == nil)
        #expect(tab.pageWaiters.pendingCount == 0)
        #expect(await tab.when(phase: .finished) == false, "a closed page files no wait")
        #expect(tab.pageWaiters.pendingCount == 0)
    }

    @Test func aClosingTabLeavesTheSetWhenItsPageAsks() async {
        let tab = page()
        let closing = PageClosingTabs()
        closing.begin("tab", page: tab)
        await tab.pageWaiters.untilPending(1)
        let before = tab.pageWaiters.evaluations

        for index in 0..<100 { tab.simulate(.titleChanged("title \(index)")) }
        #expect(closing.contains("tab"))
        #expect(tab.pageWaiters.evaluations == before, "title changes read the closing watch")

        tab.enqueuePrompt(.beforeUnload(isReload: false), origin: "https://example.com") { _ in }
        await closing.watchEnded("tab")
        #expect(!closing.contains("tab"))
    }

    @Test func aClosingTabLeavesTheSetWhenItsPageCloses() async {
        let tab = page()
        let closing = PageClosingTabs()
        closing.begin("tab", page: tab)
        await tab.pageWaiters.untilPending(1)

        tab.close()
        await closing.watchEnded("tab")
        #expect(!closing.contains("tab"))
    }
}

/// A MainWakeUpQueue whose uptime only the test moves; ``advance(by:)`` fires it.
@MainActor private final class DeadlineRig {
    let queue: MainWakeUpQueue
    private let uptime: TestUptime

    init() {
        let uptime = TestUptime()
        self.uptime = uptime
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            IdleWakeUpTimer()
        }
    }

    func advance(by duration: Duration) {
        uptime.advance(by: duration)
        queue.fire()
    }
}

/// A timer the queue arms and parks; the rig fires the queue itself.
private final class IdleWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private final class TestUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 { value.load(ordering: .relaxed) }

    func advance(by duration: Duration) {
        value.store(now + duration.nanosecondCount, ordering: .relaxed)
    }
}
