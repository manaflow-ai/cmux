import Testing
@testable import CmuxMobileOnboarding

/// D6 (terminal QA round 10): on a loaded phone the "Connect your Mac" step's
/// Continue tap was lost. The step swapped two buttons ("Continue" / "Not now")
/// when the active space's online Mac appeared, so a finger already down on one
/// was left on a view that had been removed. The step now has one call to action
/// whose label and emphasis follow the state, and whose action is resolved when
/// the tap lands.
@Suite struct PairMacCallToActionTests {
    @Test func oneIdentityAcrossTheMacComingOnline() {
        let waiting = PairMacCallToAction(macOnline: false)
        let online = PairMacCallToAction(macOnline: true)
        #expect(waiting.id == online.id)
        #expect(waiting.id == PairMacCallToAction.accessibilityIdentifier)
    }

    @Test func labelAndEmphasisFollowTheState() {
        let waiting = PairMacCallToAction(macOnline: false)
        let online = PairMacCallToAction(macOnline: true)
        #expect(waiting.title == "Not now")
        #expect(waiting.emphasis == .text)
        #expect(online.title == "Continue")
        #expect(online.emphasis == .primary)
    }

    /// A flip while the finger is down (touch-down on "Not now", touch-up on
    /// "Continue", or the reverse) still advances: the action is resolved from
    /// the state at touch-up, and both states advance.
    @Test(arguments: [(false, true), (true, false), (false, false), (true, true)])
    func actionResolvedAtTouchUpAlwaysAdvances(down: Bool, up: Bool) {
        var cta = PairMacCallToAction(macOnline: down)
        cta = PairMacCallToAction(macOnline: up)
        #expect(cta.action == .advance)
    }
}
