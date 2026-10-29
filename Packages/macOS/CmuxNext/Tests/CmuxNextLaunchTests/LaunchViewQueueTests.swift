import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The web views of the agent tabs a launch shows: none is made before the first
/// frame (each tab draws its picture there); until startup completes, each is made only in its own
/// afterFirstFrame post, the focused pane's first, and a tab outside a focused pane that shows a
/// drawing terminal posts only once the pane region is ready. After completion a view is made at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchViewQueueTests {
    @Test func viewsWaitForTheFirstFrameThenTheFocusedTabGoesFirst() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        #expect(tabs.ask("left", focused: false, startup: s.startup))
        #expect(tabs.ask("focused", focused: true, startup: s.startup))
        #expect(tabs.ask("right", focused: false, startup: s.startup))
        for _ in 0..<3 { s.fire() }
        #expect(tabs.shown.isEmpty, "no web view before the first frame: the panes draw their pictures")
        let records = s.startup.log.records
        #expect(records.map(\.name.description) == ["AgentTabs.launchView", "AgentTabs.launchView", "AgentTabs.launchView"],
                "one post per tab")
        #expect(records.allSatisfy { $0.priority == .afterFirstFrame && $0.destination == .main })
        s.startup.firstFrameCommitted()
        for _ in 0..<6 { s.fire() }
        #expect(tabs.shown == ["focused", "left", "right"], "the focused pane's view first, then the others in order")
        #expect(s.startup.completion == nil, "the shown tabs' views do not wait for startup to complete")
        #expect(!tabs.queue.isWaiting("left"))
    }

    @Test func aTabAskedAgainKeepsItsOnePost() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        #expect(tabs.ask("tab", focused: true, startup: s.startup))
        #expect(tabs.ask("tab", focused: true, startup: s.startup))
        #expect(s.startup.log.records.count == 1)
        s.startup.firstFrameCommitted()
        #expect(tabs.ask("tab", focused: true, startup: s.startup), "a tab still waiting after the first frame keeps its place")
        for _ in 0..<3 { s.fire() }
        #expect(tabs.shown == ["tab"], "shown once, by its first request's post")
    }

    @Test func aTabShownAfterTheFirstFrameBeforeCompletionWaitsForAPost() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        s.startup.firstFrameCommitted()
        #expect(s.startup.completion == nil)
        #expect(tabs.ask("restored", focused: false, startup: s.startup),
                "a restore after the first frame makes no view in its own turn")
        #expect(tabs.shown.isEmpty)
        #expect(s.startup.log.records.map(\.name.description) == ["AgentTabs.launchView"])
        for _ in 0..<2 { s.fire() }
        #expect(tabs.shown == ["restored"], "the queue's post makes it")
    }

    @Test func aTabShownAfterCompletionMakesItsViewAtOnce() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        s.complete()
        #expect(s.startup.completion != nil)
        let posted = s.startup.log.records.count
        #expect(!tabs.ask("tab", focused: false, startup: s.startup))
        #expect(s.startup.log.records.count == posted, "nothing posted")
    }

    @Test func otherPanesTabsWaitForTheFocusedTerminalsFirstContent() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs(), reveal = LaunchReveal()
        #expect(tabs.ask("other", focused: false, paneGate: reveal, startup: s.startup))
        #expect(tabs.ask("other", focused: false, paneGate: reveal, startup: s.startup))
        #expect(tabs.queue.isWaiting("other"))
        s.startup.firstFrameCommitted()
        for _ in 0..<3 { s.fire() }
        #expect(tabs.shown.isEmpty, "the focused terminal has no content yet: no web view delays it")
        #expect(s.startup.log.records.isEmpty, "no post before the pane region is ready")
        reveal.markReady(.pane)
        #expect(s.startup.log.records.map(\.name.description) == ["AgentTabs.launchView"], "one post, at the pane region")
        for _ in 0..<2 { s.fire() }
        #expect(tabs.shown == ["other"])
        #expect(!tabs.queue.isWaiting("other"))
    }

    @Test func aReadyPaneRegionGatesNothing() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs(), reveal = LaunchReveal()
        reveal.markReady(.pane)
        #expect(tabs.ask("other", focused: false, paneGate: reveal, startup: s.startup))
        #expect(s.startup.log.records.count == 1, "posted at once")
        s.startup.firstFrameCommitted()
        for _ in 0..<2 { s.fire() }
        #expect(tabs.shown == ["other"])
    }

    @Test func aMissedFirstFrameReleasesTheViews() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        #expect(tabs.ask("tab", focused: true, startup: s.startup))
        s.startup.firstFrameMissed(nil)
        for _ in 0..<2 { s.fire() }
        #expect(tabs.shown == ["tab"], "no view waits for a frame that may not come")
    }

    @Test func aQuitBeforeTheFirstFrameMakesNoView() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        #expect(tabs.ask("tab", focused: true, startup: s.startup))
        s.startup.beginQuit()
        s.startup.firstFrameCommitted()
        for _ in 0..<2 { s.fire() }
        #expect(tabs.shown.isEmpty)
        #expect(!tabs.ask("other", focused: true, startup: s.startup), "quitting: nothing waits")
    }

    @Test func noLaunchMakesEveryViewAtOnce() {
        let tabs = LaunchViewTabs()
        #expect(!tabs.ask("tab", focused: true, startup: nil))
    }
}

/// A queue and the tabs it showed, in order.
@MainActor
private final class LaunchViewTabs {
    let queue = LaunchViewQueue()
    var shown: [String] = []

    /// Asks whether `key`'s view waits; its show records `key`.
    func ask(_ key: String, focused: Bool, paneGate: LaunchReveal? = nil, startup: StartupScheduler?) -> Bool {
        queue.waitsAtLaunch(key, focused: focused, paneGate: paneGate, startup: startup) { [weak self] in self?.shown.append(key) }
    }
}
