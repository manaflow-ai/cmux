import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat whose page the hibernation froze (perf-lead.md F3) runs no script, so its transport
/// frames wait in the pacer, the ones its page waits on too, and none thaws the page; the router's
/// stream never sees them. When the page thaws, what waited goes as for a hidden pane: all of it
/// once the pane shows, else the frames the page waits on. Before, the transport delivered into
/// the frozen page and each delivery would have had to thaw it.
@MainActor
struct AgentPaneFrozenHoldTests {
    @Test func aFrozenPageGetsNoCallEvenForFramesItWaitsOn() {
        let rig = AgentPaneHiddenPacingTests.Rig(hidden: true)
        rig.pacer.setPageFrozen(true)
        rig.arrive(urgent: true)
        rig.arrive(urgent: true)
        #expect(rig.calls == 0, "a frozen page got a transport call")
        #expect(rig.pacer.held)

        rig.pacer.setPageFrozen(false)
        #expect(rig.calls == 1)
        #expect(!rig.pacer.held)
    }

    @Test func framesHeldForAFrozenVisiblePaneGoWhenItThaws() {
        let rig = AgentPaneHiddenPacingTests.Rig(hidden: false)
        rig.pacer.setPageFrozen(true)
        rig.arrive()
        #expect(rig.calls == 0)
        rig.pacer.setPageFrozen(false)
        #expect(rig.calls == 1)
    }

    /// Thawed while still hidden: frames the page does not wait on stay held until the pane shows,
    /// as for any hidden pane.
    @Test func aThawedHiddenPaneKeepsHoldingFramesItsPageDoesNotWaitOn() {
        let rig = AgentPaneHiddenPacingTests.Rig(hidden: true)
        rig.pacer.setPageFrozen(true)
        rig.arrive()
        rig.pacer.setPageFrozen(false)
        #expect(rig.calls == 0)
        #expect(rig.pacer.held)
    }
}
