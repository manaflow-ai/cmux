import Testing

@testable import CmuxAppKitSupportUI

@Suite struct SidebarScrollerVisibilityStateTests {
    @Test func bracketedLiveScrollStaysVisibleUntilScrollEnds() {
        var state = SidebarScrollerVisibilityState()

        #expect(state.handle(.willStartLiveScroll) == .show)
        #expect(state.handle(.didLiveScroll) == .show)
        #expect(state.handle(.didEndLiveScroll) == .fade)
    }

    @Test func unbracketedLegacyMouseScrollShowsThenFades() {
        var state = SidebarScrollerVisibilityState()

        #expect(state.handle(.didLiveScroll) == .showThenFade)
    }
}
