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
/// person has been away from them a minute, through the same probe, ranking and pace. The
/// neighbors stay out of the budget, and so do the tabs the panes of a workspace on screen or of
/// the workspace left last show (`Front.warm`), so Ctrl-Tab, a column scroll and a switch back
/// show live pages. The shown tabs of workspaces left before that (`Front.parked`) count, in one
/// idleness order with every other page and a bounded credit.
@Suite struct HiddenPageWarmBudgetTests {
    private func page(_ key: String, minutes: Double, focus: Int = 0, front: HibernationPlanner.Front? = nil) -> HibernationPlanner.Candidate {
        var candidate = HibernationPlanner.Candidate(key: key, hiddenFor: minutes * 60)
        candidate.recentFocusCount = focus
        candidate.front = front
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

    /// A parked workspace's shown tab ranks with every other page, with a bounded credit: four
    /// parked fronts hidden 20 minutes do not push out the tab the person left 2 minutes ago in the
    /// pane they work in (and showed often), nor one nobody shows hidden 10 minutes. Before, fronts
    /// went strictly last, so once they filled the budget no other hidden tab stayed live.
    @Test func parkedFrontsRankWithTheOtherPagesWithABoundedCredit() {
        let fronts = (0..<4).map { page("front\($0)", minutes: 20, front: .parked) }
        let recent = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: fronts + [page("recent", minutes: 2, focus: 15)],
                                             warmPages: 4)
        #expect(recent.due == ["front0"], "a tab left 2 minutes ago went before a workspace left 20 minutes ago")
        let unshown = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: fronts + [page("back", minutes: 10)], warmPages: 4)
        #expect(unshown.due == ["front0"], "the parked fronts' credit was not bounded")
        // Within the credit (5 minutes at the 30 minute default) the parked front is worth more.
        let close = HibernationPlanner.plan(.fallback, pressure: .normal,
                                            candidates: [page("front", minutes: 6, front: .parked), page("back", minutes: 5)], warmPages: 1)
        #expect(close.due == ["back"], "a parked front went before a tab nobody shows left about as long ago")
        let timedOut = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [page("front", minutes: 31, front: .parked)], warmPages: 1)
        #expect(timedOut.due == ["front"], "the timeout no longer applied to a shown tab of a parked pane")
    }

    /// The panes of the workspace left last (a 12-pane STRESS workspace) and the off-screen
    /// columns of the one on screen show their tabs again on the next switch back or scroll, all
    /// at once: they stay out of the budget, so a switch back wakes nothing. They neither go for
    /// the budget nor hold a place in it; the timeout still applies.
    @Test func theWorkspaceLeftLastKeepsItsShownPages() {
        let warm = (0..<12).map { page("pane\($0)", minutes: 2, front: .warm) }
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: warm + [page("back", minutes: 3)], warmPages: 4)
        #expect(plan.due.isEmpty, "the workspace left last lost live pages, so a switch back wakes them")
        let tight = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: warm + [page("back", minutes: 3)], warmPages: 0)
        #expect(tight.due == ["back"], "a warm front held a place in the budget")
        let timedOut = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [page("pane", minutes: 31, front: .warm)], warmPages: 4)
        #expect(timedOut.due == ["pane"], "the timeout no longer applied to the workspace left last")
    }

    /// The red row of the STRESS session's parked workspaces: each workspace left with a Chromium
    /// page in front kept that renderer (55 MB) for the whole 30 minute timeout, because a pane's
    /// shown tab was out of the budget: hidden-page memory grew O(workspaces), 10 parked
    /// workspaces ~550 MB, 150 several GB. Parked workspaces' shown tabs count in the budget now:
    /// past it the workspaces left longest ago let their page go after a minute; the most recently
    /// left keep theirs (and the workspace left last all of its own, `Front.warm`).
    @Test func parkedWorkspacesShownTabsCountInTheBudget() {
        let fronts = (0..<10).map { page("ws\($0)", minutes: 2 + Double($0), front: .parked) }
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: fronts, warmPages: 4)
        #expect(plan.due == ["ws9", "ws8"], "the workspaces left longest ago did not let their page go, or all went at once")
        #expect(plan.nextCheck == HibernationPlanner.Pace.normal.interval)
        let kept = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: Array(fronts.prefix(4)), warmPages: 4)
        #expect(kept.due.isEmpty, "the most recently left workspaces lost their live page")
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
        #expect(tabs.fronts == ["b": .parked])
        tabs.set(pane, order: ["a", "b", "c"], selected: "b")
        #expect(tabs.awake(radius: 1) == ["a", "c"])
        #expect(tabs.fronts == ["b": .warm])
    }

    /// The fronts of a workspace are one unit: all of a workspace on screen (an off-screen column
    /// too) and all of the workspace left last are warm, so a switch back shows every pane live,
    /// not the few a key order picked; a workspace left before that is parked as a whole.
    @Test func theFrontsOfTheWorkspaceLeftLastStayWarmTogether() {
        let workspaces = (0..<3).map { _ in NSObject() }
        let (a, b, c) = (ObjectIdentifier(workspaces[0]), ObjectIdentifier(workspaces[1]), ObjectIdentifier(workspaces[2]))
        let panes = (0..<5).map { _ in NSObject() }
        let id = panes.map { ObjectIdentifier($0) }
        var tabs = NeighborTabs()
        // Workspace a on screen: one pane visible, one in an off-screen column.
        tabs.set(id[0], order: ["a0"], selected: "a0", group: a)
        tabs.set(id[1], order: ["a1"], selected: "a1", visible: false, group: a)
        #expect(tabs.fronts == ["a0": .warm, "a1": .warm])
        // Switch to b: a's panes go off screen, b's come on.
        tabs.set(id[0], order: ["a0"], selected: "a0", visible: false, group: a)
        tabs.set(id[2], order: ["b0"], selected: "b0", group: b)
        tabs.set(id[3], order: ["b1"], selected: "b1", group: b)
        #expect(tabs.fronts == ["a0": .warm, "a1": .warm, "b0": .warm, "b1": .warm], "the workspace left last lost its warm fronts")
        // Switch to c: b is left last, a before it.
        tabs.set(id[2], order: ["b0"], selected: "b0", visible: false, group: b)
        tabs.set(id[3], order: ["b1"], selected: "b1", visible: false, group: b)
        tabs.set(id[4], order: ["c0"], selected: "c0", group: c)
        #expect(tabs.fronts == ["a0": .parked, "a1": .parked, "b0": .warm, "b1": .warm, "c0": .warm])
        // b closes: a is the workspace left last again.
        tabs.remove(id[2])
        tabs.remove(id[3])
        #expect(tabs.fronts == ["a0": .warm, "a1": .warm, "c0": .warm])
        withExtendedLifetime((workspaces, panes)) {}
    }

    /// The person works in B for minutes, goes to C, comes back to A: when C shows, A stops being
    /// the workspace left last and its fronts start to count. They hid minutes ago, but the person
    /// left them as budget pages only now: the minute's grace runs from then
    /// (`Candidate.countedFor`), so no hibernation lands in the switch's frames and a quick
    /// A -> B -> C -> A wakes nothing. Before, they were due in the same turn as the switch.
    @Test func aFrontThatJustStartedToCountWaitsAMinute() {
        var front = page("front", minutes: 10, front: .parked)
        front.countedFor = 0
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [front], warmPages: 0)
        #expect(plan.due.isEmpty, "a front that just stopped being warm was due in the turn of the switch")
        #expect(plan.nextCheck.map { abs($0 - HibernationPlanner.overBudgetMinimumHidden) < 1e-6 } == true)
        front.countedFor = HibernationPlanner.overBudgetMinimumHidden + 1
        #expect(HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [front], warmPages: 0).due == ["front"])
        // The timeout still runs from the hide.
        var old = page("old", minutes: 31, front: .parked)
        old.countedFor = 0
        #expect(HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [old], warmPages: 0).due == ["old"])
    }

    /// A page the probe keeps (it plays, holds form input, does not answer) left the budget only
    /// for a minute, then was due again: a thaw and a probe every minute for as long as it stayed
    /// hidden. Each keep in a row now doubles how long it stays out of the budget and unprobed.
    @Test func aPageKeptTwiceIsNotProbedAgainAfterAMinute() {
        var playing = page("playing", minutes: 40)
        playing.kept = HibernationPlanner.Kept(seconds: HibernationPlanner.keptBackoff + 1, times: 2)
        let plan = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [playing], warmPages: 0)
        #expect(plan.due.isEmpty, "a page kept twice was probed again after a minute")
        #expect(plan.nextCheck.map { abs($0 - (HibernationPlanner.keptBackoff - 1)) < 1e-6 } == true,
                "the next probe is not when the doubled backoff ends")
        playing.kept?.seconds = 2 * HibernationPlanner.keptBackoff + 1
        #expect(HibernationPlanner.plan(.fallback, pressure: .normal, candidates: [playing], warmPages: 0).due == ["playing"])
        #expect(HibernationPlanner.keptHold(times: 40) == 32 * HibernationPlanner.keptBackoff, "the backoff is not bounded")
    }

    /// Pages already being prepared take their share of the pass: a switch sends many events
    /// (every pane reports), and each used to start `Pace.perPass` more probes.
    @Test func probesInFlightTakeTheirShareOfThePass() {
        let candidates = (0..<20).map { page("t\($0)", minutes: 2 + Double($0)) }
        let busy = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates, warmPages: 4,
                                           inFlight: HibernationPlanner.Pace.normal.perPass)
        #expect(busy.due.isEmpty, "a pass started more probes while a full pass was in flight")
        #expect(busy.nextCheck == HibernationPlanner.Pace.normal.interval)
        #expect(busy.allDue.count == 16)
        let one = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates, warmPages: 4, inFlight: 1)
        #expect(one.due == ["t19"])
    }
}
