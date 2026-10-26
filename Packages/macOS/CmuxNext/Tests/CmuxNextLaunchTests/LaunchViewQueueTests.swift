import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The web views of the tabs a launch shows (p08-startup-042): none is made before the first frame
/// (each tab draws its picture there); after it, one afterFirstFrame post per tab, the focused pane's
/// first, all before startup completes. A tab shown after the first frame makes its view at once.
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

    @Test func aTabShownAfterTheFirstFrameMakesItsViewAtOnce() {
        let s = StartupTestScheduler(), tabs = LaunchViewTabs()
        s.startup.firstFrameCommitted()
        #expect(!tabs.ask("tab", focused: false, startup: s.startup))
        #expect(s.startup.log.records.isEmpty, "nothing posted")
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
    func ask(_ key: String, focused: Bool, startup: StartupScheduler?) -> Bool {
        queue.waitsForFirstFrame(key, focused: focused, startup: startup) { [weak self] in self?.shown.append(key) }
    }
}
