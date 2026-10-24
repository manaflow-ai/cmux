import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import Testing

/// #17587: an agent chat's first web view (`AgentPaneView.init`, the first `WKProcessPool`, about
/// 150 ms of main thread) is never made before the first window frame: the pane draws the chat's
/// saved page meanwhile. Before, a chat in the focused pane (or a launch whose focus was not known
/// yet) made its view inside the window build, ahead of the first frame.
@MainActor @Suite struct AgentViewLaunchDeferralTests {
    static func store() -> AgentTabStore {
        AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
    }

    static func gate() -> FirstFrameGate {
        FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
    }

    @Test func theFocusedChatsViewWaitsForTheFirstWindowFrame() {
        let tabs = Self.store()
        let firstFrame = Self.gate()
        var shown = 0
        let deferred = tabs.deferAtLaunch("tab_chat", reveal: LaunchReveal(deadline: .seconds(60)), firstFrame: firstFrame,
                                          focusedPane: "pane_1", pane: "pane_1", focusedDraws: false) { shown += 1 }
        #expect(deferred, "the window build makes no web view")
        #expect(shown == 0)
        firstFrame.open()
        #expect(shown == 1, "the view is made once the first window frame committed")
        let again = tabs.deferAtLaunch("tab_chat", reveal: LaunchReveal(deadline: .seconds(60)), firstFrame: firstFrame,
                                       focusedPane: "pane_1", pane: "pane_1", focusedDraws: false) { shown += 1 }
        #expect(!again, "after the first frame a focused chat makes its view at once")
    }

    @Test func aChatOutsideTheFocusedPaneAlsoWaitsForTheFocusedTerminalsFrame() {
        let tabs = Self.store()
        let firstFrame = Self.gate()
        let reveal = LaunchReveal(deadline: .seconds(60))
        var shown = 0
        let deferred = tabs.deferAtLaunch("tab_side", reveal: reveal, firstFrame: firstFrame,
                                          focusedPane: "pane_1", pane: "pane_2", focusedDraws: true) { shown += 1 }
        #expect(deferred)
        firstFrame.open()
        #expect(shown == 0, "the focused terminal has not drawn yet")
        reveal.markReady(.pane)
        #expect(shown == 1)
    }

    @Test func noLaunchToWaitForMakesTheViewAtOnce() {
        let tabs = Self.store()
        var shown = 0
        let deferred = tabs.deferAtLaunch("tab_chat", reveal: LaunchReveal(deadline: .seconds(60)), firstFrame: .alreadyOpen(),
                                          focusedPane: nil, pane: "pane_1", focusedDraws: false) { shown += 1 }
        #expect(!deferred, "a services graph built outside the launch (tests, a later window) waits for no frame")
        #expect(shown == 0, "the caller makes the view itself")
    }
}
