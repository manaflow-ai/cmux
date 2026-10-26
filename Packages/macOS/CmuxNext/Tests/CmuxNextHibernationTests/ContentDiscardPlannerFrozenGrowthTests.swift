import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``FrozenGrowthRule``: a frozen page whose memory grew by max(50 MB, 25 %) since it froze is
/// discarded with the frozen pages of its opener group for ``DiscardReason/frozenWithGrowingMemory``
/// (Chrome's `FreezingPolicy`, components/performance_manager/freezing/freezing_policy.cc), the lead
/// rule and the person's choices still keep a page, and the readings are three one-shot wakeups per
/// frozen page, never a period.
@Suite struct ContentDiscardPlannerFrozenGrowthTests {
    let setting = BrowserHibernationSetting.fallback
    let start = ContinuousClock.now
    let megabyte: UInt64 = 1 << 20

    func page(_ key: String) -> ContentDiscardPlanner.Candidate {
        ContentDiscardPlanner.Candidate(key: key, hiddenFor: 600)
    }

    /// A reading of a page alone in its processes.
    func alone(_ key: String, _ megabytes: UInt64) -> FrozenGrowthRule.Reading {
        FrozenGrowthRule.Reading(bytes: megabytes * megabyte, sharers: [key])
    }

    /// Frozen pages, each alone in its processes, with their memory at freeze.
    func frozen(_ pages: [String: UInt64]) -> FrozenGrowthRule {
        var growth = FrozenGrowthRule()
        for (key, megabytes) in pages { growth.froze(key, at: start, reading: alone(key, megabytes)) }
        return growth
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
        var growth = frozen(["grows": 100, "steady": 100])
        let growing = growth.record(["grows": alone("grows", 160), "steady": alone("steady", 120)])
        #expect(growing == ["grows"])
        let plan = growth.plan(growing: growing, groups: { [$0] },
                               candidates: ["grows": page("grows"), "steady": page("steady")], setting: setting)
        #expect(plan.due == ["grows"])
        #expect(plan.exemptions.isEmpty)
    }

    @Test func withoutAFreshReadingAtFreezeTheFirstReadingIsTheBaseline() {
        var growth = FrozenGrowthRule()
        growth.froze("a", at: start, reading: nil)
        let grew1 = growth.record(["a": alone("a", 100)])
        #expect(grew1.isEmpty, "the first reading has nothing to grow from")
        #expect(growth.pages["a"]?.baseline == 100 * megabyte)
        let grew2 = growth.record(["a": alone("a", 150)])
        #expect(grew2 == ["a"])
    }

    /// A page kept from the discard (a download it runs) stays frozen and read: its growth is
    /// reported once, and only new growth reports it again.
    @Test func aGrowthIsReportedOnce() {
        var growth = frozen(["a": 100])
        let grew1 = growth.record(["a": alone("a", 200)])
        #expect(grew1 == ["a"])
        let grew2 = growth.record(["a": alone("a", 200)])
        #expect(grew2.isEmpty, "the same growth was reported on every reading")
        let grew3 = growth.record(["a": alone("a", 249)])
        #expect(grew3.isEmpty)
        let grew4 = growth.record(["a": alone("a", 250)])
        #expect(grew4 == ["a"])
    }

    /// A shared renderer's footprint is split between the pages on it: when a sharer closes or is
    /// discarded, the frozen page's share goes up with no growth in the page. 3 pages on 300 MB
    /// read 100 MB each; the 2 others go, and the frozen one reads 300 MB.
    @Test func aSharerThatLeavesIsNoGrowth() {
        var growth = FrozenGrowthRule()
        let all: Set<String> = ["a", "b", "c"]
        for key in all { growth.froze(key, at: start, reading: nil) }
        let shared = FrozenGrowthRule.Reading(bytes: 100 * megabyte, sharers: all)
        let grew1 = growth.record(["a": shared, "b": shared, "c": shared])
        #expect(grew1.isEmpty)
        #expect(growth.pages["a"]?.baseline == 100 * megabyte)
        growth.thawed("b")
        growth.thawed("c")
        let grew2 = growth.record(["a": .init(bytes: 300 * megabyte, sharers: ["a"])])
        #expect(grew2.isEmpty, "a sharer's leaving was growth")
        #expect(growth.pages["a"]?.baseline == 300 * megabyte, "the new sharers take a new baseline")
        let grew3 = growth.record(["a": .init(bytes: 380 * megabyte, sharers: ["a"])])
        #expect(grew3 == ["a"])
    }

    /// An awake page on the same renderer runs script: the shared number is not the frozen page's.
    @Test func aSharerThatIsAwakeOwnsPartOfTheNumber() {
        var growth = FrozenGrowthRule()
        growth.froze("frozen", at: start, reading: .init(bytes: 100 * megabyte, sharers: ["frozen", "awake"]))
        #expect(growth.pages["frozen"]?.baseline == nil, "a number shared with an awake page was a baseline")
        let grew1 = growth.record(["frozen": .init(bytes: 400 * megabyte, sharers: ["frozen", "awake"])])
        #expect(grew1.isEmpty,
                "the awake page's growth was the frozen page's")
        growth.froze("awake", at: start, reading: nil)
        let grew2 = growth.record(["frozen": .init(bytes: 400 * megabyte, sharers: ["frozen", "awake"])])
        #expect(grew2.isEmpty)
        #expect(growth.pages["frozen"]?.baseline == 400 * megabyte, "with both frozen the number is a baseline")
    }

    /// cmux's lead rule (p07-memory.md section 3.C): the person's form input keeps the page from
    /// this discard too, as audio, capture, a download and a `beforeunload` that asks do.
    @Test func formInputKeepsAGrowingPage() {
        var growth = frozen(["draft": 100])
        var draft = page("draft")
        draft.hasFormInput = true
        let growing = growth.record(["draft": alone("draft", 400)])
        let plan = growth.plan(growing: growing, groups: { [$0] },
                               candidates: ["draft": draft], setting: setting)
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions["draft"] == .formInput)
    }

    /// The person's own choices keep a frozen page too (stricter than Chrome): a tab pinned or a site
    /// marked Never Hibernate after the page froze, DevTools opened on it, or hibernation off.
    @Test func thePersonsChoicesKeepAGrowingPage() {
        var pinned = page("pinned")
        pinned.isPinned = true
        var excluded = page("excluded")
        excluded.host = "example.com"
        var inspected = page("inspected")
        inspected.hasDevTools = true
        let candidates = ["pinned": pinned, "excluded": excluded, "inspected": inspected]
        var growth = frozen(["pinned": 100, "excluded": 100, "inspected": 100])
        let growing = growth.record(candidates.keys.reduce(into: [String: FrozenGrowthRule.Reading]()) { $0[$1] = alone($1, 400) })
        #expect(growing == ["excluded", "inspected", "pinned"])
        var excluding = setting
        excluding.exclusions = ["example.com"]
        let plan = growth.plan(growing: growing, groups: { [$0] }, candidates: candidates, setting: excluding)
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions == ["pinned": .pinned, "excluded": .excluded, "inspected": .devTools])
    }

    /// `browser.hibernation: "off"` disables it completely, this discard too.
    @Test func hibernationOffKeepsAGrowingPage() {
        var growth = frozen(["a": 100])
        let growing = growth.record(["a": alone("a", 400)])
        let plan = growth.plan(growing: growing, groups: { [$0] },
                               candidates: ["a": page("a")], setting: BrowserHibernationSetting(mode: .off))
        #expect(plan.due.isEmpty, "a growing page went with hibernation off")
        #expect(plan.exemptions == ["a": .disabled])
    }

    /// Chrome discards a frozen browsing instance: the popup grew, its frozen opener goes with it. A
    /// frozen member the lead rule keeps stays; one that shows (no candidate) stays.
    @Test func theOpenerAndItsPopupAreDiscardedTogether() {
        var growth = frozen(["popup": 80, "opener": 200, "download": 50])
        let family: Set<String> = ["opener", "popup", "download", "shown"]
        var download = page("download")
        download.isDownloading = true
        let growing = growth.record(["popup": alone("popup", 300), "opener": alone("opener", 210)])
        #expect(growing == ["popup"])
        let plan = growth.plan(growing: growing, groups: { family.contains($0) ? family : [$0] },
                               candidates: ["opener": page("opener"), "popup": page("popup"), "download": download,
                                            "other": page("other")],
                               setting: setting)
        #expect(Set(plan.due) == ["opener", "popup"])
        #expect(plan.exemptions == ["download": .downloading])
    }

    /// A member that is not frozen is no part of the frozen instance: a pinned or Never Hibernate
    /// opener of a growing popup stays loaded, as does a member hidden a moment ago.
    @Test func aMemberThatIsNotFrozenStays() {
        var growth = frozen(["popup": 80])
        var pinned = page("pinned")
        pinned.isPinned = true
        var excluded = page("excluded")
        excluded.host = "example.com"
        var excluding = setting
        excluding.exclusions = ["example.com"]
        let family: Set<String> = ["pinned", "excluded", "fresh", "popup"]
        let growing = growth.record(["popup": alone("popup", 300)])
        let plan = growth.plan(growing: growing, groups: { _ in family },
                               candidates: ["pinned": pinned, "excluded": excluded, "fresh": page("fresh"), "popup": page("popup")],
                               setting: excluding)
        #expect(plan.due == ["popup"])
        #expect(plan.exemptions.isEmpty)
    }

    /// A member the probe kept lately is not planned again on every reading.
    @Test func aMemberTheProbeKeptLatelyIsNotAskedAgain() {
        var growth = frozen(["popup": 80, "opener": 100])
        var opener = page("opener")
        opener.recentlyKept = true
        let growing = growth.record(["popup": alone("popup", 300)])
        let plan = growth.plan(growing: growing, groups: { _ in ["opener", "popup"] },
                               candidates: ["opener": opener, "popup": page("popup")], setting: setting)
        #expect(plan.due == ["popup"])
    }

    @Test func theOpenerGroupFollowsOpenersBothWaysAndTransitively() {
        let openers = ["popup": "opener", "grandchild": "popup", "sibling": "opener", "elsewhere": "other"]
        #expect(FrozenGrowthRule.openerGroup(of: "grandchild", openers: openers) == ["opener", "popup", "grandchild", "sibling"])
        #expect(FrozenGrowthRule.openerGroup(of: "other", openers: openers) == ["other", "elsewhere"])
        #expect(FrozenGrowthRule.openerGroup(of: "alone", openers: openers) == ["alone"])
    }

    @Test func eachMemberIsPlannedOnceWhenTwoMembersGrow() {
        var growth = frozen(["a": 100, "b": 100])
        let growing = growth.record(["a": alone("a", 200), "b": alone("b", 200)])
        let plan = growth.plan(growing: growing, groups: { _ in ["a", "b"] },
                               candidates: ["a": page("a"), "b": page("b")], setting: setting)
        #expect(plan.due == ["a", "b"])
    }

    /// No periodic sampling: a frozen page has its readings at +5, +30 and +120 minutes, then none.
    @Test func aFrozenPageWakesAtMostThreeTimesThenNever() {
        var growth = frozen(["a": 100])
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
        growth.froze("a", at: start, reading: alone("a", 100))
        growth.froze("b", at: start + .seconds(60), reading: alone("b", 100))
        #expect(growth.nextWakeup == start + .seconds(300))
        growth.wake(at: start + .seconds(3 * 3_600))
        #expect(growth.nextWakeup == nil)
    }

    @Test func aThawedPageHasNoMoreReadings() {
        var growth = frozen(["a": 100])
        growth.thawed("a")
        #expect(growth.nextWakeup == nil)
        let grew = growth.record(["a": alone("a", 900)])
        #expect(grew.isEmpty)
        growth = frozen(["a": 100, "b": 100])
        growth.removeAll()
        #expect(growth.pages.isEmpty)
    }
}
