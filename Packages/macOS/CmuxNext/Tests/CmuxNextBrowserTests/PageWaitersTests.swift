import AppKit
import CmuxNextCompat
@testable import CmuxNextBrowser
@testable import CmuxNextWakeups
import Foundation
import Testing

/// Keyed waits on a page: `page.when(phase:timeout:)` and
/// `page.whenPrompt(kind:timeout:)` read their condition only when the page's phase changes or it
/// adds a prompt, resume once on the transition, and resume with nil on their timeout, on cancel or
/// when the page closes. The timeouts are entries on the engine's MainWakeUpQueue, whose uptime the
/// test moves.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PageWaitersTests {
    private static let url = URL(string: "https://example.com/")!
    /// A timeout no test reaches (the rig's uptime moves only when a test advances it).
    private static let never: Duration = .seconds(3_600)

    private func page(_ rig: DeadlineRig = DeadlineRig()) -> MockBrowserTab {
        MockBrowserEngine(completesNavigationsImmediately: false, waitDeadlines: rig.queue).makeMockTab(BrowserTabConfiguration())
    }

    @Test func aPhaseWaiterReadsNothingOnTitleChangesAndResumesOnceOnItsTransition() async {
        let tab = page()
        let finished = Task { await tab.when(phase: .finished, timeout: Self.never) }
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
        #expect(await tab.when(phase: .idle, timeout: Self.never))
        #expect(await tab.when(phase: { $0 == .idle }, timeout: Self.never) == .idle)
        #expect(tab.pageWaiters.pendingCount == 0)
    }

    @Test func aPromptWaiterReadsOnlyAddedPromptsAndResumesWhenThePageAsks() async throws {
        let tab = page()
        let asks = Task { await tab.whenPrompt(kind: { $0.isBeforeUnload }, timeout: Self.never) }
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

    @Test func aWaitResumesWithNilOnItsTimeoutAndDropsIt() async {
        let rig = DeadlineRig()
        let tab = page(rig)
        let finished = Task { await tab.when(phase: .finished, timeout: .seconds(1)) }
        await tab.pageWaiters.untilPending(1)
        #expect(rig.queue.count == 1)

        rig.advance(by: .seconds(2))
        #expect(await finished.value == false)
        #expect(tab.pageWaiters.pendingCount == 0)
        #expect(rig.queue.count == 0)
    }

    @Test func aResumeCancelsItsTimeout() async {
        let rig = DeadlineRig()
        let tab = page(rig)
        let asks = Task { await tab.whenPrompt(kind: { $0.isBeforeUnload }, timeout: .seconds(60)) }
        await tab.pageWaiters.untilPending(1)
        #expect(rig.queue.count == 1)

        tab.enqueuePrompt(.beforeUnload(isReload: true), origin: "https://example.com") { _ in }
        #expect(await asks.value != nil)
        #expect(rig.queue.count == 0, "the resume cancelled its timeout")
    }

    @Test func aCancelledWaitResumesWithNil() async {
        let rig = DeadlineRig()
        let tab = page(rig)
        let finished = Task { await tab.when(phase: .finished, timeout: Self.never) }
        await tab.pageWaiters.untilPending(1)
        finished.cancel()
        #expect(await finished.value == false)
        #expect(tab.pageWaiters.pendingCount == 0)
        #expect(rig.queue.count == 0, "the cancel dropped its timeout")
    }

    @Test func closingThePageEndsItsWaitsAndLaterOnes() async {
        let rig = DeadlineRig()
        let tab = page(rig)
        let finished = Task { await tab.when(phase: .finished, timeout: Self.never) }
        let asks = Task { await tab.whenPrompt(kind: { $0.isBeforeUnload }, timeout: Self.never) }
        await tab.pageWaiters.untilPending(2)

        tab.close()
        #expect(await finished.value == false)
        #expect(await asks.value == nil)
        #expect(tab.pageWaiters.pendingCount == 0)
        #expect(rig.queue.count == 0)
        #expect(await tab.when(phase: .finished, timeout: Self.never) == false, "a closed page files no wait")
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

    @Test func aClosingTabLeavesTheSetWhenItsPageNeitherAsksNorCloses() async {
        let rig = DeadlineRig()
        let tab = page(rig)
        let closing = PageClosingTabs()
        closing.begin("tab", page: tab)
        await tab.pageWaiters.untilPending(1)

        rig.advance(by: PageClosingTabs.decideTimeout / 2)
        #expect(closing.contains("tab"), "the page still has its time to decide")
        rig.advance(by: PageClosingTabs.decideTimeout * 2)
        await closing.watchEnded("tab")
        #expect(!closing.contains("tab"))
        #expect(rig.queue.count == 0)
    }

    /// A real WebKit page's setters drive its waits: its load resumes a phase wait once, its title
    /// changes read no waiter, and its close resumes the rest with nil.
    @Test func aWebKitPageResumesItsWaitsFromItsOwnSetters() async throws {
        let rig = DeadlineRig()
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), waitDeadlines: rig.queue).makeWebKitTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        page.webView.frame = window.contentLayoutRect
        window.contentView = page.webView
        window.orderFrontRegardless()
        var closed = false
        defer {
            window.orderOut(nil)
            window.close()
            if !closed { page.close() }
        }
        let finished = Task { await page.when(phase: .finished, timeout: Self.never) }
        let unmet = Task { await page.whenPrompt(kind: { $0.isBeforeUnload }, timeout: Self.never) }
        await page.pageWaiters.untilPending(2)

        page.webView.loadHTMLString("<title>t0</title><p>page</p>", baseURL: nil)
        #expect(await finished.value, "the load's finish resumed the phase wait")
        #expect(page.pageWaiters.pendingCount == 1)
        let atFinish = page.pageWaiters.evaluations

        let titles = TitleSeen(page: page, last: "t20")
        _ = try await page.webView.evaluateJavaScript("for (let n = 1; n <= 20; n++) document.title = 't' + n; 0")
        await titles.reached()
        #expect(page.pageWaiters.evaluations == atFinish, "title changes read \(page.pageWaiters.evaluations - atFinish) waiter conditions")

        page.close()
        closed = true
        #expect(await unmet.value == nil, "the close resumed the pending wait with nil")
        #expect(page.pageWaiters.pendingCount == 0)
        #expect(rig.queue.count == 0)
    }
}

/// Resumes ``reached()`` once the WebKit page reports the title `last` (its title coalescer may skip
/// the ones before it).
@MainActor private final class TitleSeen {
    private var seen = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: UUID?
    private weak var page: WebKitTab?

    init(page: WebKitTab, last: String) {
        self.page = page
        observer = page.observeNavigationEvents { [weak self] event in
            guard case .titleChanged(let title) = event, title == last, let self else { return }
            seen = true
            waiting?.resume()
            waiting = nil
        }
    }

    func reached() async {
        if !seen { await withCheckedContinuation { waiting = $0 } }
        if let observer { page?.removeNavigationObserver(observer) }
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
private nonisolated final class IdleWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class TestUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 { value.load(ordering: .relaxed) }

    func advance(by duration: Duration) {
        value.store(now + duration.nanosecondCount, ordering: .relaxed)
    }
}
