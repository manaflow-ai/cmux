import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// Chrome's freeze eligibility (components/performance_manager/freezing/freezing_policy.cc): a page with
/// the notification permission, a held Web Lock, a held IndexedDB lock or a load in progress never
/// freezes, and a browsing instance (an opener and the pages it opened) freezes and thaws as a whole.
/// The rules apply with feature `memoryFreezeEligibility`; off, the plan is the one from before.
@Suite struct FreezePlanTests {
    let setting = BrowserHibernationSetting.fallback

    func page(_ key: String, hiddenFor: Double = 31, notifications: Bool = false, loading: Bool = false) -> HibernationPlanner.Candidate {
        var candidate = HibernationPlanner.Candidate(key: key, hiddenFor: hiddenFor, allowsNotifications: notifications)
        candidate.isLoading = loading
        return candidate
    }

    /// A page whose site may show notifications never freezes: a frozen page shows none.
    @Test func aPageThatMayShowNotificationsNeverFreezes() {
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("chat", hiddenFor: 10_000, notifications: true), page("docs")])
        #expect(plan.due == ["docs"])
        #expect(plan.kept["chat"] == .notifications)
        #expect(plan.nextCheck == nil, "no deadline for a page only an event frees")
    }

    @Test func aLoadingPageDoesNotFreeze() {
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("slow", loading: true)])
        #expect(plan.due.isEmpty)
        #expect(plan.kept["slow"] == .loading)
    }

    /// The opener shows (it is no candidate): its popup, past its delay, stays awake with it.
    @Test func anOpenerAndItsPopupWithOneVisibleDoNotFreeze() {
        let groups: (String) -> Set<String> = { _ in ["opener", "popup"] }
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("popup", hiddenFor: 600)], groups: groups)
        #expect(plan.due.isEmpty)
        #expect(plan.kept["popup"] == .openerGroup)
    }

    @Test func anOpenerGroupFreezesWhenEveryMemberIsDue() {
        let groups: (String) -> Set<String> = { ["opener", "popup"].contains($0) ? ["opener", "popup"] : [$0] }
        let waiting = HibernationPlanner.freezePlan(setting, candidates: [page("opener"), page("popup", hiddenFor: 20)], groups: groups)
        #expect(waiting.due.isEmpty, "the popup is not due yet")
        #expect(waiting.kept["opener"] == .openerGroup)
        #expect(abs((waiting.nextCheck ?? 0) - 10) < 1e-9, "the group is looked at again when the popup is due")

        let due = HibernationPlanner.freezePlan(setting, candidates: [page("opener"), page("popup", hiddenFor: 30), page("alone")], groups: groups)
        #expect(Set(due.due) == ["opener", "popup", "alone"])
        #expect(due.groups["opener"] == ["opener", "popup"])
        #expect(due.groups["popup"] == ["opener", "popup"])
        #expect(due.groups["alone"] == nil, "a page without an opener group freezes alone")
    }

    /// A member frozen already (or asked before its freeze) counts as ready.
    @Test func aFrozenMemberCountsAsReady() {
        let groups: (String) -> Set<String> = { _ in ["opener", "popup"] }
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("popup")], groups: groups, frozen: ["opener"])
        #expect(plan.due == ["popup"])
    }

    /// A member kept for a reason of its own keeps the whole group awake.
    @Test func aKeptMemberKeepsItsGroupAwake() {
        let groups: (String) -> Set<String> = { _ in ["opener", "popup"] }
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("opener", notifications: true), page("popup")], groups: groups)
        #expect(plan.due.isEmpty)
        #expect(plan.kept == ["opener": .notifications, "popup": .openerGroup])
    }

    @Test func theGroupIsAskedOnlyForDuePages() {
        var asked: [String] = []
        _ = HibernationPlanner.freezePlan(setting, candidates: [page("due"), page("waiting", hiddenFor: 1), page("chat", notifications: true)],
                                          groups: { asked.append($0); return [$0] })
        #expect(asked == ["due"])
    }

    /// Feature `memoryFreezeEligibility` off: Chrome's reasons keep no page, as before them.
    @Test func withoutChromesReasonsTheNotificationPageAndTheLoadingPageFreeze() {
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("chat", notifications: true), page("slow", loading: true)],
                                                 chromeReasons: false)
        #expect(Set(plan.due) == ["chat", "slow"])
        #expect(plan.kept.isEmpty)
    }

    @Test func freezingOffKeepsEveryPageWithNoReason() {
        var off = setting
        off.freezeSeconds = nil
        let plan = HibernationPlanner.freezePlan(off, candidates: [page("chat", notifications: true), page("docs")])
        #expect(plan == FreezePlan())
    }
}

/// The App's side of the rules (`FreezeEligibility`): the switch, the probe's locks, the opener groups'
/// thaw, the pages kept lately, and the load watch.
@MainActor @Suite struct FreezeEligibilityTests {
    let setting = BrowserHibernationSetting.fallback
    let groups: (String) -> Set<String> = { ["opener", "popup"].contains($0) ? ["opener", "popup"] : [$0] }

    func makeRules(enabled: Bool = true, loading: Set<String> = []) -> FreezeEligibility {
        let rules = FreezeEligibility()
        rules.configure(isEnabled: enabled, work: MainWorkScheduler(budget: MainFrameBudget()), isLoading: { loading.contains($0) }, onLoaded: {})
        return rules
    }

    func page(_ key: String, notifications: Bool = false) -> HibernationPlanner.Candidate {
        HibernationPlanner.Candidate(key: key, hiddenFor: 31, allowsNotifications: notifications)
    }

    /// Off, the plan is the one from before the rules: the notification page and the group freeze.
    @Test func offThePlanIsTheOneFromBefore() {
        let plan = makeRules(enabled: false).plan(setting, candidates: [page("chat", notifications: true), page("popup")], frozen: [], groups: groups)
        #expect(Set(plan.due) == ["chat", "popup"])
        #expect(plan.kept.isEmpty)
    }

    @Test func onTheLoadingPageWaits() {
        let rules = makeRules(loading: ["slow"])
        defer { rules.stop() }
        let plan = rules.plan(setting, candidates: [page("slow"), page("done")], frozen: [], groups: { [$0] })
        #expect(plan.due == ["done"])
        #expect(plan.kept["slow"] == .loading)
    }

    @Test(arguments: [true, false])
    func aPageHoldingALockStaysAwake(webLock: Bool) {
        let probe = webLock ? PageProbe(heldWebLock: true) : PageProbe(openIndexedDB: true)
        #expect(makeRules().keeps(probe), "a Web Lock or IndexedDB holder froze")
        #expect(!makeRules(enabled: false).keeps(probe), "off, the probe's locks do not count")
    }

    @Test func whatAFreezeStopsKeepsThePageEitherWay() {
        #expect(makeRules().keeps(PageProbe(playingMedia: true)))
        #expect(makeRules(enabled: false).keeps(PageProbe(playingMedia: true)))
        #expect(!makeRules().keeps(PageProbe()))
    }

    /// The opener shows: its frozen popup thaws with it, and a probe still out for the popup does not
    /// freeze it until a plan finds the whole group due again.
    @Test func aGroupThawsTogether() {
        let rules = makeRules()
        let plan = rules.plan(setting, candidates: [page("opener"), page("popup")], frozen: [], groups: groups)
        #expect(Set(plan.due) == ["opener", "popup"])
        #expect(rules.thaw("opener") == ["popup"])
        #expect(rules.thaw("popup").isEmpty, "each group thaws once")
        #expect(!rules.mayFreeze("popup"))
        #expect(rules.thaw("alone").isEmpty)
        _ = rules.plan(setting, candidates: [page("opener"), page("popup")], frozen: [], groups: groups)
        #expect(rules.mayFreeze("popup"), "due again with its whole group")
    }

    /// The probe keeps the popup (it holds a lock): its frozen opener thaws, and the popup is asked again after the delay.
    @Test func aKeptMemberThawsItsGroupAndIsAskedAgainAfterTheDelay() {
        let rules = makeRules()
        _ = rules.plan(setting, candidates: [page("opener"), page("popup")], frozen: [], groups: groups)
        let start = ContinuousClock.now
        #expect(rules.keep("popup", at: start) == ["opener"])
        #expect(rules.keptLeft("popup", threshold: 30, now: start + .seconds(10)).map { abs($0 - 20) < 1e-6 } == true)
        #expect(rules.keptLeft("popup", threshold: 30, now: start + .seconds(31)) == nil)
        #expect(rules.keptLeft("popup", threshold: 30, now: start + .seconds(10)) == nil, "an ended keep is dropped")
        rules.keep("popup", at: start)
        rules.shown("popup")
        #expect(rules.keptLeft("popup", threshold: 30, now: start) == nil, "showing the page clears its keep")
    }

    /// A page kept for its load is planned again when the load ends: an event, no timer.
    @Test(.timeLimit(.minutes(1))) func theLoadEndPlansAgain() async {
        let load = TestLoad()
        let rules = FreezeEligibility()
        let work = MainWorkScheduler(budget: MainFrameBudget())
        await confirmation { loaded in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                rules.configure(isEnabled: true, work: work, isLoading: { [weak load] _ in load?.isLoading }, onLoaded: {
                    loaded()
                    done.resume()
                })
                let plan = rules.plan(setting, candidates: [page("slow")], frozen: [], groups: { [$0] })
                #expect(plan.kept["slow"] == .loading)
                load.isLoading = false
            }
        }
        rules.stop()
    }
}

/// A page's load state, observable as `BrowserTab.state` is.
@MainActor @Observable private final class TestLoad {
    var isLoading = true
}
