@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// Chromium's high-rate page events merged per browser per frame on the main-thread scheduler
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section E, task 219): visible work for a shown tab, held by a
/// hidden tab's node until it shows, automation for an agent's tab; every other event FIFO and immediate.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CEFMergedEventsTests {
    /// The acceptance: 50 progress events for a hidden tab post no task, and apply once (the latest) on show.
    @Test func fiftyProgressEventsForAHiddenTabRunNoVisibleTaskAndApplyOnceOnShow() {
        let rig = MergeRig()
        let pane = VisibilityNode(root: "pane", own: .visible)
        let tabNode = VisibilityNode("tab:hidden", own: .hidden, parent: pane)
        let page = MergePage(browser: 7)
        rig.merger.follow(page, node: tabNode)
        for step in 1...50 {
            #expect(rig.merger.holds(.progress(browser: 7, value: Double(step) / 50), for: page))
        }
        #expect(rig.work.postedCount(.visible) == 0, "a hidden tab's events posted a visible task")
        #expect(rig.work.postedCount(.background) == 0, "the node holds them; no app hidden wake is installed")
        rig.frame()
        rig.frame()
        #expect(page.applied.isEmpty, "a hidden tab's events applied while it was hidden")
        #expect(rig.merger.heldBrowsers == 1)

        tabNode.set(.visible)
        rig.frame()
        #expect(page.applied == [.progress(browser: 7, value: 1)], "one apply, the latest value, on show")
        rig.frame()
        #expect(page.applied.count == 1, "the background queue's copy applied nothing more")
        #expect(rig.merger.heldBrowsers == 0)
    }

    /// A visible tab's 100 titles in one frame apply once, in the next frame, as one visible task.
    @Test func aVisibleTabsTitlesApplyOnceInTheNextFrame() {
        let rig = MergeRig()
        let tabNode = VisibilityNode(root: "tab:shown", own: .visible)
        let page = MergePage(browser: 3)
        rig.merger.follow(page, node: tabNode)
        for index in 1...100 { _ = rig.merger.holds(.title(browser: 3, title: "t\(index)"), for: page) }
        #expect(page.applied.isEmpty, "a merged event applied inline")
        #expect(rig.work.postedCount(.visible) == 1, "one visible task for the browser, not one per event")
        rig.runTurns()
        #expect(page.applied.isEmpty, "visible work waits for the frame while frames run")
        rig.frame()
        #expect(page.applied == [.title(browser: 3, title: "t100")])
    }

    /// A crash, a commit, a load end and a dialog are never merged: each applies now, after the browser's held events.
    @Test func eventsThatAreNotMergedApplyAtOnceAfterTheHeldOnes() {
        let rig = MergeRig()
        let page = MergePage(browser: 5)
        rig.merger.follow(page, node: VisibilityNode(root: "tab:hidden", own: .hidden))
        _ = rig.merger.holds(.progress(browser: 5, value: 0.3), for: page)
        _ = rig.merger.holds(.title(browser: 5, title: "Loading"), for: page)
        let crash = CEFShimEvent.renderTerminated(browser: 5, status: 2, code: 11, text: "", end: .first)
        #expect(!rig.merger.holds(crash, for: page), "a crash was merged")
        #expect(page.applied == [.progress(browser: 5, value: 0.3), .title(browser: 5, title: "Loading")],
                "the held events apply before the crash the caller applies now")
        for event in [CEFShimEvent.loadStart(browser: 5, url: "https://a.test/", fromPost: false), .loadEnd(browser: 5, httpStatus: 200),
                      .beforeUnloadDialog(browser: 5, token: 1, isReload: false)] {
            #expect(!rig.merger.holds(event, for: page), "\(event) was merged")
        }
        #expect(rig.merger.heldBrowsers == 0)
    }

    /// Each kind keeps its latest value; the kinds apply in the order they first came.
    @Test func eachKindKeepsItsLatestValueInFirstArrivalOrder() {
        let rig = MergeRig()
        let page = MergePage(browser: 9)
        rig.merger.follow(page, node: VisibilityNode(root: "tab:shown", own: .visible))
        for event in [CEFShimEvent.address(browser: 9, url: "https://a.test/"), .title(browser: 9, title: "A"),
                      .address(browser: 9, url: "https://b.test/"), .favicon(browser: 9, url: "https://b.test/f.ico"),
                      .progress(browser: 9, value: 0.5), .title(browser: 9, title: "B")] {
            #expect(rig.merger.holds(event, for: page))
        }
        rig.frame()
        #expect(page.applied == [.address(browser: 9, url: "https://b.test/"), .title(browser: 9, title: "B"),
                                 .favicon(browser: 9, url: "https://b.test/f.ico"), .progress(browser: 9, value: 0.5)])
    }

    /// An agent-driven hidden tab is never held (the agent reads its state while it is hidden): one automation task.
    @Test func anAgentDrivenHiddenTabAppliesOnTheNextTurnAsAutomation() {
        let rig = MergeRig()
        let page = MergePage(browser: 4)
        page.agentDriven = true
        rig.merger.follow(page, node: VisibilityNode(root: "tab:hidden", own: .hidden))
        for step in 1...10 { _ = rig.merger.holds(.progress(browser: 4, value: Double(step) / 10), for: page) }
        #expect(rig.work.postedCount(.automation) == 1)
        #expect(rig.work.postedCount(.visible) == 0)
        rig.frame()
        #expect(page.applied == [.progress(browser: 4, value: 1)])
    }

    /// A tab no node follows applies in its next frame as node-free visible work.
    @Test func aTabWithNoNodeAppliesInTheNextFrame() {
        let rig = MergeRig()
        let page = MergePage(browser: 2)
        _ = rig.merger.holds(.address(browser: 2, url: "https://a.test/"), for: page)
        _ = rig.merger.holds(.address(browser: 2, url: "https://b.test/"), for: page)
        #expect(rig.work.postedCount(.visible) == 1)
        rig.frame()
        #expect(page.applied == [.address(browser: 2, url: "https://b.test/")])
    }

    /// A hidden tab's title, icon and address show outside it (its tab strip item, the sidebar, the session record):
    /// they are never held for the show, and run as one background task, never as visible work.
    @Test func aHiddenTabsTitleRunsAsOneBackgroundTask() {
        let rig = MergeRig()
        let page = MergePage(browser: 11)
        rig.merger.follow(page, node: VisibilityNode(root: "tab:hidden", own: .hidden))
        _ = rig.merger.holds(.progress(browser: 11, value: 0.5), for: page)
        for index in 1...20 { _ = rig.merger.holds(.title(browser: 11, title: "t\(index)"), for: page) }
        #expect(rig.work.postedCount(.background) == 1)
        #expect(rig.work.postedCount(.visible) == 0)
        rig.frame()
        #expect(page.applied == [.progress(browser: 11, value: 0.5), .title(browser: 11, title: "t20")])
    }

    /// A title held for a shown tab's next frame, when the tab hides before that frame, runs as one background task:
    /// the tab strip item, the sidebar and the session record get it without the tab showing again.
    @Test func aShownTabsHeldTitleRunsAsBackgroundWhenTheTabHidesBeforeTheFrame() {
        let rig = MergeRig()
        let tabNode = VisibilityNode(root: "tab:shown", own: .visible)
        let page = MergePage(browser: 12)
        rig.merger.follow(page, node: tabNode)
        _ = rig.merger.holds(.title(browser: 12, title: "Inbox (3)"), for: page)
        tabNode.set(.hidden)
        #expect(rig.work.postedCount(.background) == 1, "the hide moved the held title to one background task")
        rig.frame()
        rig.frame()
        #expect(page.applied == [.title(browser: 12, title: "Inbox (3)")], "the title waited for the tab to show again")
        #expect(rig.merger.heldBrowsers == 0)
        tabNode.set(.visible)
        rig.frame()
        #expect(page.applied.count == 1, "the show applied the title again")
    }

    /// A shown tab's held progress, when the tab hides before the frame, stays held by the node until it shows.
    @Test func aShownTabsHeldProgressWaitsForTheShowWhenTheTabHides() {
        let rig = MergeRig()
        let tabNode = VisibilityNode(root: "tab:shown", own: .visible)
        let page = MergePage(browser: 13)
        rig.merger.follow(page, node: tabNode)
        _ = rig.merger.holds(.progress(browser: 13, value: 0.4), for: page)
        tabNode.set(.hidden)
        rig.frame()
        rig.frame()
        #expect(page.applied.isEmpty, "a hidden tab's progress applied while it was hidden")
        #expect(rig.work.postedCount(.background) == 0, "the node holds it; no app hidden wake is installed")
        tabNode.set(.visible)
        rig.frame()
        #expect(page.applied == [.progress(browser: 13, value: 0.4)])
    }

    /// Following a shown node moves a hidden tab's held events to it: they apply in the next frame.
    @Test func followingAShownNodeAppliesWhatAHiddenOneHeld() {
        let rig = MergeRig()
        let page = MergePage(browser: 6)
        rig.merger.follow(page, node: VisibilityNode(root: "tab:hidden", own: .hidden))
        _ = rig.merger.holds(.progress(browser: 6, value: 0.7), for: page)
        rig.frame()
        #expect(page.applied.isEmpty)
        let shown = VisibilityNode(root: "tab:moved", own: .visible)
        rig.merger.follow(page, node: shown)
        rig.frame()
        #expect(page.applied == [.progress(browser: 6, value: 0.7)])
    }

    /// With the feature off (no scheduler) nothing is held, and turning it off applies what was held.
    @Test func withNoSchedulerEveryEventAppliesAtOnce() {
        let rig = MergeRig()
        let page = MergePage(browser: 8)
        rig.merger.follow(page, node: VisibilityNode(root: "tab:hidden", own: .hidden))
        #expect(rig.merger.holds(.progress(browser: 8, value: 0.2), for: page))
        rig.merger.work = nil
        #expect(page.applied == [.progress(browser: 8, value: 0.2)], "turning merging off applies what it held")
        #expect(!rig.merger.holds(.progress(browser: 8, value: 0.4), for: page))
        #expect(!rig.merger.holds(.title(browser: 8, title: "x"), for: nil), "no tab: applied now")
        #expect(rig.merger.heldBrowsers == 0)
    }

    /// An event naming another browser than its tab's applies now.
    @Test func anEventOfAnotherBrowserIsNotHeld() {
        let rig = MergeRig()
        let page = MergePage(browser: 1)
        #expect(!rig.merger.holds(.title(browser: 2, title: "other"), for: page))
        #expect(rig.merger.heldBrowsers == 0)
    }
}

/// A page the merger applies to: its browser, whether an agent drives it, and what it was given.
@MainActor
private final class MergePage {
    var browser: Int32?
    var agentDriven = false
    var applied: [CEFShimEvent] = []

    init(browser: Int32) {
        self.browser = browser
    }
}

/// A merger over a test scheduler whose run loop turns and frames the test runs by hand.
@MainActor
private final class MergeRig {
    let work: MainWorkScheduler
    let merger: CEFMergedEvents<MergePage>
    private let turns = MergeTurns()
    private let clock = MergeClock()
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let turns = turns, clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { clock.now }), ledger: WakeupLedger(),
                                         performTurn: { turns.queued.append($0) }) { _ in MergeFakeLink() }
        merger = CEFMergedEvents(reading: .init(browser: { $0.browser }, isAgentDriven: { $0.agentDriven },
                                                apply: { page, event in page.applied.append(event) }))
        // A frame client keeps the fake link up, so visible work waits for the frames the test fires.
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        merger.work = work
    }

    /// Runs the queued run loop turns, and the turns they queue.
    func runTurns() {
        while !turns.queued.isEmpty { turns.queued.removeFirst()() }
    }

    /// Runs the queued turns, then one frame 17 ms later, then the turns it queued.
    func frame() {
        runTurns()
        clock.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        runTurns()
    }
}

@MainActor
private final class MergeTurns {
    var queued: [@MainActor () -> Void] = []
}

@MainActor
private final class MergeClock {
    var now: UInt64 = 1_000_000_000
}

@MainActor
private final class MergeFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
