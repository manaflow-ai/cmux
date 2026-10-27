import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// The control sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, FG307): an agent action's wait for a pending
/// navigation is the page's keyed wait (``BrowserPageWaiting``): a title or progress tick reads nothing, the load's
/// end resumes it (Chromium's `WebContentsObserver::DidStopLoading`). The condition wait the other pages use has its
/// own suite (CmuxNextControlTests, ControlConditionWaitTests).
@MainActor @Suite(.serialized)
struct ControlMainWorkSweepTests {
    @MainActor final class Outcome {
        var value: Bool?
    }

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    @Test func aPendingNavigationWaitIsThePagesKeyedWait() async {
        let tab = MockBrowserEngine(completesNavigationsImmediately: false)
            .makeMockTab(BrowserTabConfiguration(initialURL: nil))
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: URL(string: "https://example.com")))
        #expect(tab.state.isLoading)
        let (outcome, work) = (Outcome(), Self.work())
        let waiting = Task { @MainActor in
            outcome.value = await AppBrowserPage.awaitPendingNavigation(tab, within: .seconds(30), work: work)
        }
        await tab.pageWaiters.untilPending(1)
        let evaluations = tab.pageWaiters.evaluations
        tab.simulate(.titleChanged("loading"))
        tab.simulate(.progress(0.5))
        #expect(tab.pageWaiters.evaluations == evaluations, "a title or progress tick read the navigation wait")
        tab.simulate(.finished(id))
        await waiting.value
        #expect(outcome.value == true, "the load's end did not resume the wait")
    }

    @Test func aPageThatIsNotLoadingAnswersAtOnce() async {
        let tab = MockBrowserEngine(completesNavigationsImmediately: false)
            .makeMockTab(BrowserTabConfiguration(initialURL: nil))
        #expect(!tab.state.isLoading)
        #expect(await AppBrowserPage.awaitPendingNavigation(tab, within: .seconds(30), work: Self.work()))
    }
}
