import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``FrozenGrowthRule``: a frozen page whose memory grew by max(50 MB, 25 %) since it froze is
/// discarded with its opener group for ``DiscardReason/frozenWithGrowingMemory`` (Chrome's
/// `FreezingPolicy`, components/performance_manager/freezing/freezing_policy.cc), the lead rule
/// still keeps a page, and the readings are three one-shot wakeups per frozen page, never a period.
@Suite struct ContentDiscardPlannerFrozenGrowthTests {
    let setting = BrowserHibernationSetting.fallback
    let start = ContinuousClock.now
    let megabyte: UInt64 = 1 << 20

    func page(_ key: String) -> ContentDiscardPlanner.Candidate {
        ContentDiscardPlanner.Candidate(key: key, hiddenFor: 600)
    }

    @Test func theThresholdIsFiftyMegabytesOrAQuarterOfTheMemoryAtFreeze() {
        #expect(FrozenGrowthRule.threshold(baseline: 100 * megabyte) == 50 * megabyte)
        #expect(FrozenGrowthRule.threshold(baseline: 400 * megabyte) == 100 * megabyte)
        #expect(!FrozenGrowthRule.grew(from: 100 * megabyte, to: 149 * megabyte))
        #expect(FrozenGrowthRule.grew(from: 100 * megabyte, to: 150 * megabyte))
        #expect(!FrozenGrowthRule.grew(from: 400 * megabyte, to: 499 * megabyte))
        #expect(FrozenGrowthRule.grew(from: 400 * megabyte, to: 500 * megabyte))
        #expect(!FrozenGrowthRule.grew(from: 400 * megabyte, to: 300 * megabyte), "a page that shrank grew")
    }

    @Test func growthOverTheThresholdIsDue() {
        var growth = FrozenGrowthRule()
        growth.froze("grows", at: start, bytes: 100 * megabyte)
        growth.froze("steady", at: start, bytes: 100 * megabyte)
        let growing = growth.record(["grows": 160 * megabyte, "steady": 120 * megabyte])
        #expect(growing == ["grows"])
        let plan = growth.plan(growing: growing, groups: { [$0] },
                               candidates: ["grows": page("grows"), "steady": page("steady")], setting: setting)
        #expect(plan.due == ["grows"])
        #expect(plan.exemptions.isEmpty)
    }

    @Test func withoutAFreshReadingAtFreezeTheFirstReadingIsTheBaseline() {
        var growth = FrozenGrowthRule()
        growth.froze("a", at: start, bytes: nil)
        #expect(growth.record(["a": 100 * megabyte]).isEmpty, "the first reading has nothing to grow from")
        #expect(growth.pages["a"]?.baseline == 100 * megabyte)
        #expect(growth.record(["a": 150 * megabyte]) == ["a"])
    }

    /// cmux's lead rule (p07-memory.md section 3.C): the person's form input keeps the page from
    /// this discard too, as audio, capture, a download and a `beforeunload` that asks do.
    @Test func formInputKeepsAGrowingPage() {
        var growth = FrozenGrowthRule()
        growth.froze("draft", at: start, bytes: 100 * megabyte)
        var draft = page("draft")
        draft.hasFormInput = true
        let plan = growth.plan(growing: growth.record(["draft": 400 * megabyte]), groups: { [$0] },
                               candidates: ["draft": draft], setting: setting)
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions["draft"] == .formInput)
    }

    /// A pinned page or a Never Hibernate host does not keep it: Chrome always allows this discard
    /// past protected reasons, as the person's own.
    @Test func protectedReasonsDoNotKeepAGrowingPage() {
        var growth = FrozenGrowthRule()
        growth.froze("pinned", at: start, bytes: 100 * megabyte)
        var pinned = page("pinned")
        pinned.isPinned = true
        let plan = growth.plan(growing: growth.record(["pinned": 400 * megabyte]), groups: { [$0] },
                               candidates: ["pinned": pinned], setting: setting)
        #expect(plan.due == ["pinned"])
    }

    /// Chrome freezes and discards a browsing instance together: the popup grew, its opener goes
    /// with it. A member the lead rule keeps stays; one that shows (no candidate) stays.
    @Test func theOpenerAndItsPopupAreDiscardedTogether() {
        var growth = FrozenGrowthRule()
        growth.froze("popup", at: start, bytes: 80 * megabyte)
        growth.froze("opener", at: start, bytes: 200 * megabyte)
        let family: Set<String> = ["opener", "popup", "download", "shown"]
        var download = page("download")
        download.isDownloading = true
        let growing = growth.record(["popup": 300 * megabyte, "opener": 210 * megabyte])
        #expect(growing == ["popup"])
        let plan = growth.plan(growing: growing, groups: { family.contains($0) ? family : [$0] },
                               candidates: ["opener": page("opener"), "popup": page("popup"), "download": download,
                                            "other": page("other")],
                               setting: setting)
        #expect(Set(plan.due) == ["opener", "popup"])
        #expect(plan.exemptions == ["download": .downloading])
    }

    @Test func theOpenerGroupFollowsOpenersBothWaysAndTransitively() {
        let openers = ["popup": "opener", "grandchild": "popup", "sibling": "opener", "elsewhere": "other"]
        #expect(FrozenGrowthRule.openerGroup(of: "grandchild", openers: openers) == ["opener", "popup", "grandchild", "sibling"])
        #expect(FrozenGrowthRule.openerGroup(of: "other", openers: openers) == ["other", "elsewhere"])
        #expect(FrozenGrowthRule.openerGroup(of: "alone", openers: openers) == ["alone"])
    }

    @Test func eachMemberIsPlannedOnceWhenTwoMembersGrow() {
        var growth = FrozenGrowthRule()
        growth.froze("a", at: start, bytes: 100 * megabyte)
        growth.froze("b", at: start, bytes: 100 * megabyte)
        let growing = growth.record(["a": 200 * megabyte, "b": 200 * megabyte])
        let plan = growth.plan(growing: growing, groups: { _ in ["a", "b"] },
                               candidates: ["a": page("a"), "b": page("b")], setting: setting)
        #expect(plan.due == ["a", "b"])
    }

    /// No periodic sampling: a frozen page has its readings at +5, +30 and +120 minutes, then none.
    @Test func aFrozenPageWakesAtMostThreeTimesThenNever() {
        var growth = FrozenGrowthRule()
        growth.froze("a", at: start, bytes: 100 * megabyte)
        var wakeups: [Duration] = []
        while let next = growth.nextWakeup {
            wakeups.append(next - start)
            growth.wake(at: next)
            #expect(wakeups.count <= 3, "a frozen page kept waking")
            if wakeups.count > 3 { break }
        }
        #expect(wakeups == [.seconds(300), .seconds(1_800), .seconds(7_200)])
        #expect(growth.pages["a"] != nil, "the page is still frozen and still read at planner passes")
    }

    @Test func oneLateWakeupServesEveryReadingDueByThen() {
        var growth = FrozenGrowthRule()
        growth.froze("a", at: start, bytes: 100 * megabyte)
        growth.froze("b", at: start + .seconds(60), bytes: 100 * megabyte)
        #expect(growth.nextWakeup == start + .seconds(300))
        growth.wake(at: start + .seconds(3 * 3_600))
        #expect(growth.nextWakeup == nil)
    }

    @Test func aThawedPageHasNoMoreReadings() {
        var growth = FrozenGrowthRule()
        growth.froze("a", at: start, bytes: 100 * megabyte)
        growth.thawed("a")
        #expect(growth.nextWakeup == nil)
        #expect(growth.record(["a": 900 * megabyte]).isEmpty)
    }
}
