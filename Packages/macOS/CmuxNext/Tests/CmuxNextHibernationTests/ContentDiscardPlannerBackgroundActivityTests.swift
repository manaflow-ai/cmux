import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// Chrome's `kBackgroundActivity` (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc):
/// a page that changed its title or icon while hidden is protected from proactive discards only;
/// urgent discards ignore it, and showing the page clears it
/// (`PageLiveStateDecorator::Data::UpdatedTitleOrFaviconInBackground`).
@Suite struct ContentDiscardPlannerBackgroundActivityTests {
    let planner = ContentDiscardPlanner()
    let setting = BrowserHibernationSetting.fallback
    let pace = ContentDiscardPlanner.Pace(perPass: 2, interval: 5, minimumHidden: 0)
    let icon = URL(string: "https://mail.example.com/favicon.ico")!
    let unreadIcon = URL(string: "https://mail.example.com/favicon-unread.ico")!

    func page(_ key: String = "p", active: Bool) -> ContentDiscardPlanner.Candidate {
        var candidate = ContentDiscardPlanner.Candidate(key: key, hiddenFor: 7_200)
        candidate.hasBackgroundActivity = active
        return candidate
    }

    @Test func backgroundActivityProtectsFromTheTimeoutOnly() {
        let active = page(active: true)
        let proactive = planner.eligibility(of: active, setting: setting, for: .proactive)
        #expect(proactive.result == .protected)
        #expect(proactive.reason == .backgroundActivity)
        for reason in [DiscardReason.urgent, .external, .frozenWithGrowingMemory] {
            #expect(planner.eligibility(of: active, setting: setting, for: reason).result == .eligible, "\(reason)")
        }
        #expect(CannotDiscardReason(chromeReason: "kBackgroundActivity") == .backgroundActivity)
        #expect(CannotDiscardReason.backgroundActivity.rawValue == "background_activity")
    }

    @Test func theTimeoutKeepsAnActivePageAndPressureTakesIt() {
        let candidates = [page("active", active: true), page("quiet", active: false)]
        let timeout = planner.plan(setting, for: .proactive, threshold: 600, pace: pace, candidates: candidates)
        #expect(timeout.due == ["quiet"])
        #expect(timeout.exemptions == ["active": .backgroundActivity])
        let urgent = planner.plan(setting, for: .urgent, threshold: 600, pace: pace, candidates: candidates)
        #expect(Set(urgent.due) == ["active", "quiet"])
        #expect(urgent.exemptions.isEmpty)
        let browser = HibernationPlanner.plan(setting, pressure: .warning, candidates: candidates)
        #expect(browser.exemptions["active"] == nil, "the browser's pressure plan ignores it too")
    }

    @Test func aTitleOrIconChangeWhileHiddenMakesThePageActive() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("mail", look: .init(document: 1, title: "Inbox", icon: icon))
        changed = activity.note("mail", look: .init(document: 1, title: "Inbox", icon: icon))
        #expect(!changed, "nothing changed")
        #expect(!activity.contains("mail"))
        changed = activity.note("mail", look: .init(document: 1, title: "Inbox (1)", icon: icon))
        #expect(changed)
        #expect(activity.contains("mail"))
        changed = activity.note("mail", look: .init(document: 1, title: "Inbox (2)", icon: icon))
        #expect(!changed, "active once per hidden period")

        activity.hide("chat", look: .init(document: 1, title: "Chat", icon: icon))
        changed = activity.note("chat", look: .init(document: 1, title: "Chat", icon: unreadIcon))
        #expect(changed)
        #expect(activity.active == ["mail", "chat"])
    }

    /// Chrome counts neither a document's first title nor its first icon
    /// (`PerformanceManagerTabHelper::TitleWasSet`, `DidUpdateFaviconURL`): a page that loads hidden is
    /// not active.
    @Test func aDocumentsFirstTitleAndIconDoNotCount() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("new", look: .init(document: 1))
        changed = activity.note("new", look: .init(document: 1, title: "Inbox"))
        #expect(!changed)
        changed = activity.note("new", look: .init(document: 1, title: "Inbox", icon: icon))
        #expect(!changed)
        changed = activity.note("new", look: .init(document: 1, title: "Inbox (1)", icon: icon))
        #expect(changed, "the second title counts")

        activity.hide("redirect", look: .init(document: 1, title: "Inbox", icon: icon))
        changed = activity.note("redirect", look: .init(document: 2, title: "Sign in", icon: icon))
        #expect(!changed, "a new document starts over")
        changed = activity.note("redirect", look: .init(document: 2, title: "Sign in", icon: unreadIcon))
        #expect(!changed, "its first icon")
        changed = activity.note("redirect", look: .init(document: 2, title: "Sign in again", icon: unreadIcon))
        #expect(changed)
    }

    /// A hidden page that reloads itself at the same address (meta refresh, `location.reload()`) is a
    /// new document: the commit clears its title, and the same title coming back is its first.
    @Test func aSameAddressReloadIsANewDocumentAndDoesNotCount() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("dash", look: .init(document: 1, title: "Dashboard", icon: icon))
        changed = activity.note("dash", look: .init(document: 2, title: nil, icon: icon))
        #expect(!changed)
        changed = activity.note("dash", look: .init(document: 2, title: "Dashboard", icon: icon))
        #expect(!changed, "the reloaded document's first title")
        changed = activity.note("dash", look: .init(document: 3, title: "Dashboard", icon: icon))
        #expect(!changed, "a reload whose commit and title arrive in one change")
        #expect(!activity.contains("dash"))
    }

    /// The person started a navigation and switched away before it committed: the new document's
    /// first title and first icon are not activity.
    @Test func aNavigationThatCommitsAfterTheHideDoesNotCount() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("nav", look: .init(document: 1, title: "Search", icon: icon))
        changed = activity.note("nav", look: .init(document: 2, title: nil, icon: nil))
        #expect(!changed)
        changed = activity.note("nav", look: .init(document: 2, title: "Result", icon: unreadIcon))
        #expect(!changed, "its first title and first icon")
        changed = activity.note("nav", look: .init(document: 2, title: "Result (1)", icon: unreadIcon))
        #expect(changed)
    }

    /// A same-document navigation (pushState, a fragment) changes the address, not the document
    /// (`BrowserTabState.documentGeneration`), so its title change counts, as in Chrome.
    @Test func aSameDocumentNavigationWithANewTitleCounts() {
        var activity = PageBackgroundActivity()
        activity.hide("spa", look: .init(document: 4, title: "Chat - general", icon: icon))
        let counted = activity.note("spa", look: .init(document: 4, title: "Chat - random", icon: icon))
        #expect(counted)
        #expect(activity.contains("spa"))
    }

    /// An agent drives the page (a lease, a recent call): its changes become what the page shows and
    /// do not count; the page's own change after the agent leaves does.
    @Test func anAgentsChangesDoNotCount() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("agent", look: .init(document: 1, title: "Inbox", icon: icon))
        changed = activity.note("agent", look: .init(document: 1, title: "Compose", icon: icon), counts: false)
        #expect(!changed)
        changed = activity.note("agent", look: .init(document: 1, title: "Sent", icon: unreadIcon), counts: false)
        #expect(!changed)
        #expect(!activity.contains("agent"), "an agent's title and icon changes leave it eligible")
        changed = activity.note("agent", look: .init(document: 1, title: "Sent", icon: unreadIcon))
        #expect(!changed, "nothing changed since the agent's look")
        changed = activity.note("agent", look: .init(document: 1, title: "Inbox (1)", icon: unreadIcon))
        #expect(changed, "the page's own change after the agent left")
    }

    /// A page with background activity is kept from the timeout for its updates, so it does not
    /// freeze either (a frozen page runs no script, and its title could no longer change).
    @Test func anActivePageDoesNotFreeze() {
        let plan = HibernationPlanner.freezePlan(setting, candidates: [page("active", active: true), page("quiet", active: false)])
        #expect(plan.due == ["quiet"])
    }

    @Test func showingThePageClearsItAndAPageNeverHiddenIsNeverActive() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("mail", look: .init(document: 1, title: "Inbox"))
        activity.note("mail", look: .init(document: 1, title: "Inbox (1)"))
        activity.forget("mail")
        #expect(!activity.contains("mail"))
        changed = activity.note("mail", look: .init(document: 1, title: "Inbox (2)"))
        #expect(!changed, "shown pages are not watched")

        activity.hide("mail", look: .init(document: 1, title: "Inbox"))
        activity.note("mail", look: .init(document: 1, title: "Inbox (1)"))
        activity.hide("mail", look: .init(document: 1, title: "Inbox (1)"))
        #expect(!activity.contains("mail"), "a new hidden period starts clean")
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func theWatchFollowsAHiddenPageUntilItShows() async {
        let page = TestPage(document: 1, title: "Inbox")
        let watch = PageActivityWatch(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        watch.isEnabled = true
        await confirmation { activated in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                watch.hide("mail", look: { [weak page] in page?.look }, onActive: {
                    activated()
                    done.resume()
                })
                page.title = "Inbox (1)"
            }
        }
        #expect(watch.contains("mail"))
        watch.forget("mail")
        #expect(!watch.contains("mail"), "show clears the flag")
        watch.stop()
    }

    @MainActor @Test func anOffWatchWatchesNothing() {
        let page = TestPage(document: 1, title: "Inbox")
        let watch = PageActivityWatch(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        watch.hide("mail", look: { [weak page] in page?.look }, onActive: { Issue.record("an off watch called back") })
        page.title = "Inbox (1)"
        #expect(!watch.contains("mail"))
        #expect(watch.activity.active.isEmpty)
    }
}

/// A page's title and icon, observable as `BrowserTab.state` is.
@MainActor @Observable private final class TestPage {
    var document: UInt64
    var title: String
    var icon: URL?

    init(document: UInt64, title: String) {
        self.document = document
        self.title = title
    }

    var look: PageBackgroundActivity.Look {
        PageBackgroundActivity.Look(document: document, title: title, icon: icon)
    }
}
