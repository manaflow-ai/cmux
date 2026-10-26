import CmuxNextHibernation
import CmuxNextSettings
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
    let inbox = URL(string: "https://mail.example.com/inbox")!
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
        activity.hide("mail", look: .init(url: inbox, title: "Inbox", icon: icon))
        changed = activity.note("mail", look: .init(url: inbox, title: "Inbox", icon: icon))
        #expect(!changed, "nothing changed")
        #expect(!activity.contains("mail"))
        changed = activity.note("mail", look: .init(url: inbox, title: "Inbox (1)", icon: icon))
        #expect(changed)
        #expect(activity.contains("mail"))
        changed = activity.note("mail", look: .init(url: inbox, title: "Inbox (2)", icon: icon))
        #expect(!changed, "active once per hidden period")

        activity.hide("chat", look: .init(url: inbox, title: "Chat", icon: icon))
        changed = activity.note("chat", look: .init(url: inbox, title: "Chat", icon: unreadIcon))
        #expect(changed)
        #expect(activity.active == ["mail", "chat"])
    }

    /// Chrome counts neither a document's first title nor its first icon
    /// (`PerformanceManagerTabHelper::TitleWasSet`, `DidUpdateFaviconURL`): a page that loads hidden is
    /// not active.
    @Test func aDocumentsFirstTitleAndIconDoNotCount() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("new", look: .init(url: inbox))
        changed = activity.note("new", look: .init(url: inbox, title: "Inbox"))
        #expect(!changed)
        changed = activity.note("new", look: .init(url: inbox, title: "Inbox", icon: icon))
        #expect(!changed)
        changed = activity.note("new", look: .init(url: inbox, title: "Inbox (1)", icon: icon))
        #expect(changed, "the second title counts")

        activity.hide("redirect", look: .init(url: inbox, title: "Inbox", icon: icon))
        let other = URL(string: "https://mail.example.com/login")!
        changed = activity.note("redirect", look: .init(url: other, title: "Sign in", icon: icon))
        #expect(!changed, "a new document starts over")
        changed = activity.note("redirect", look: .init(url: other, title: "Sign in", icon: unreadIcon))
        #expect(!changed, "its first icon")
        changed = activity.note("redirect", look: .init(url: other, title: "Sign in again", icon: unreadIcon))
        #expect(changed)
    }

    @Test func showingThePageClearsItAndAPageNeverHiddenIsNeverActive() {
        var activity = PageBackgroundActivity()
        var changed: Bool
        activity.hide("mail", look: .init(url: inbox, title: "Inbox"))
        activity.note("mail", look: .init(url: inbox, title: "Inbox (1)"))
        activity.forget("mail")
        #expect(!activity.contains("mail"))
        changed = activity.note("mail", look: .init(url: inbox, title: "Inbox (2)"))
        #expect(!changed, "shown pages are not watched")

        activity.hide("mail", look: .init(url: inbox, title: "Inbox"))
        activity.note("mail", look: .init(url: inbox, title: "Inbox (1)"))
        activity.hide("mail", look: .init(url: inbox, title: "Inbox (1)"))
        #expect(!activity.contains("mail"), "a new hidden period starts clean")
    }

    @MainActor @Test(.timeLimit(.minutes(1))) func theWatchFollowsAHiddenPageUntilItShows() async {
        let page = TestPage(url: inbox, title: "Inbox")
        let watch = PageActivityWatch()
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
        let page = TestPage(url: inbox, title: "Inbox")
        let watch = PageActivityWatch()
        watch.hide("mail", look: { [weak page] in page?.look }, onActive: { Issue.record("an off watch called back") })
        page.title = "Inbox (1)"
        #expect(!watch.contains("mail"))
        #expect(watch.activity.active.isEmpty)
    }
}

/// A page's title and icon, observable as `BrowserTab.state` is.
@MainActor @Observable private final class TestPage {
    var url: URL
    var title: String
    var icon: URL?

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var look: PageBackgroundActivity.Look {
        PageBackgroundActivity.Look(url: url, title: title, icon: icon)
    }
}
