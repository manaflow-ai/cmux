@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextSettings
import Foundation
import Testing

/// Hidden things cost almost nothing (plans/cmux-next/perf-lead.md row 15, speed-of-sound F8): a
/// hidden live web page costs a whole renderer (55 MB Chromium, 29 MB WebKit, fleet 2026-10-22)
/// for the 30 minutes before `browser.hibernation` lets it go, so 20 hidden tabs held over 1 GB.
/// Hidden live pages now share one memory budget with the hidden terminal surfaces
/// (`WarmSetBudget.pageCapacity`): past it, the least valuable hidden pages hibernate once the
/// person has been away from them a minute, through the same probe, ranking and pace. The tabs a
/// pane shows (also in a parked workspace) and their neighbors stay out of the budget, so a
/// workspace switch and Ctrl-Tab still show live pages.
@Suite struct HiddenPageWarmBudgetTests {
    private func page(_ key: String, minutes: Double, focus: Int = 0, front: Bool = false) -> HibernationPlanner.Candidate {
        var candidate = HibernationPlanner.Candidate(key: key, hiddenFor: minutes * 60)
        candidate.recentFocusCount = focus
        candidate.isFront = front
        return candidate
    }

    /// The red row: twenty tabs hidden 2 to 21 minutes, all short of the 30 minute timeout, kept
    /// every renderer before. Past a budget of four, the least valuable go, a few per pass.
    @Test func hiddenPagesPastTheBudgetHibernateBeforeTheTimeout() {
        let candidates = (0..<20).map { page("t\($0)", minutes: 2 + Double($0)) }
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates, warmPages: 4)
        #expect(plan.due == ["t19", "t18"], "the longest hidden go first, never all at once")
        #expect(plan.nextCheck == HibernationPlanner.Pace.normal.interval, "the rest past the budget follow on the next pass")

        // Once the sixteen past the budget went, the four most valuable wait for the timeout.
        let kept = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: Array(candidates.prefix(4)), warmPages: 4)
        #expect(kept.due.isEmpty, "pages within the budget hibernated before the timeout")
        #expect(kept.nextCheck.map { abs($0 - 25 * 60) < 1e-6 } == true, "the next check is the first timeout (t3 at 5 min)")
    }

    /// The budget keeps the pages the person comes back to, not the newest ones.
    @Test func theBudgetKeepsTheMostValuablePages() {
        let candidates = [
            page("often-a", minutes: 9, focus: 15), page("often-b", minutes: 8, focus: 15),
            page("once-a", minutes: 3), page("once-b", minutes: 2),
        ]
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates, warmPages: 2)
        #expect(Set(plan.due) == ["once-a", "once-b"])
    }

    /// A page the person left less than a minute ago never goes for the budget (a quick look at
    /// another tab and back); the planner looks again when it reaches the minute.
    @Test func aPageThePersonJustLeftStaysOverTheBudget() {
        let candidates = (0..<10).map { page("t\($0)", minutes: 10.0 / 60) }
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates, warmPages: 2)
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck.map { abs($0 - (HibernationPlanner.overBudgetMinimumHidden - 10)) < 1e-6 } == true)
    }

    /// What each pane shows, also in a parked workspace or an off-screen column, is what a
    /// switch shows again: it stays out of the budget (the timeout and memory pressure still apply).
    @Test func eachPanesShownTabStaysOutOfTheBudget() {
        let candidates = (0..<6).map { page("front\($0)", minutes: 5, front: true) } + [page("back", minutes: 5)]
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates, warmPages: 0)
        #expect(plan.due == ["back"])
        let timedOut = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [page("front", minutes: 31, front: true)], warmPages: 0)
        #expect(timedOut.due == ["front"], "the timeout no longer applied to a shown tab of a parked pane")
    }

    /// A page the probe just kept (it plays, or holds the person's form input) is live for a
    /// reason: it neither goes for the budget nor holds a place in it.
    @Test func aPageTheProbeJustKeptStaysOutOfTheBudget() {
        var playing = page("playing", minutes: 20)
        playing.recentlyKept = true
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [playing, page("quiet", minutes: 5)], warmPages: 1)
        #expect(plan.due.isEmpty, "the probe's keep was overruled, or the kept page took the budget's place")
        let over = HibernationPlanner.plan(.fallback, pressure: .normal,
                                           candidates: [playing, page("quiet", minutes: 5), page("older", minutes: 6)], warmPages: 1)
        #expect(over.due == ["older"])
    }

    /// "off" still disables every trigger, the budget too; exempt pages never go for it.
    @Test func offAndExemptionsStillHold() {
        let candidates = (0..<10).map { page("t\($0)", minutes: 5) }
        let off = HibernationPlanner.plan(BrowserHibernationSetting(mode: .off), pressure: .normal, candidates: candidates, warmPages: 0)
        #expect(off.due.isEmpty)
        var pinned = page("pinned", minutes: 5)
        pinned.isPinned = true
        var downloading = page("dl", minutes: 5)
        downloading.isDownloading = true
        let exempt = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [pinned, downloading], warmPages: 0)
        #expect(exempt.due.isEmpty)
        #expect(exempt.exemptions == ["pinned": .pinned, "dl": .downloading])
    }

    /// The budget is sized from memory like the terminal surfaces': a few pages on every Mac, more
    /// with more memory, fewer under a pressure warning and none under critical pressure.
    @Test func theBudgetFollowsMemoryAndPressure() {
        let gigabyte: UInt64 = 1 << 30
        #expect(WarmSetBudget.forMemory(physicalBytes: 8 * gigabyte, pressure: .normal).pageCapacity == 4)
        #expect(WarmSetBudget.forMemory(physicalBytes: 16 * gigabyte, pressure: .normal).pageCapacity == 4)
        #expect(WarmSetBudget.forMemory(physicalBytes: 36 * gigabyte, pressure: .normal).pageCapacity == 10)
        #expect(WarmSetBudget.forMemory(physicalBytes: 128 * gigabyte, pressure: .normal).pageCapacity == 16)
        #expect(WarmSetBudget.forMemory(physicalBytes: 128 * gigabyte, pressure: .warning).pageCapacity == 2)
        #expect(WarmSetBudget.forMemory(physicalBytes: 128 * gigabyte, pressure: .critical).pageCapacity == 0)
    }

    /// A pane off screen (a parked workspace, an off-screen column) keeps its shown tab as its
    /// front, and wakes no neighbors.
    @Test func anOffScreenPaneKeepsItsFrontButWakesNoNeighbors() {
        let pane = ObjectIdentifier(NSObject.self)
        var tabs = NeighborTabs()
        tabs.set(pane, order: ["a", "b", "c"], selected: "b", visible: false)
        #expect(tabs.awake(radius: 1).isEmpty)
        #expect(tabs.fronts == ["b"])
        tabs.set(pane, order: ["a", "b", "c"], selected: "b")
        #expect(tabs.awake(radius: 1) == ["a", "c"])
        #expect(tabs.fronts == ["b"])
    }
}
