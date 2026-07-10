import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileSceneRefreshActionTests {
    @Test func inactiveInterruptionDoesNotBecomeBackgroundTransition() {
        #expect(MobileSceneRefreshAction.forScenePhase(.inactive) == .none)
        #expect(MobileSceneRefreshAction.forScenePhase(.background) == .enterBackground)
        #expect(MobileSceneRefreshAction.forScenePhase(.active) == .resumeForeground)
    }
}
