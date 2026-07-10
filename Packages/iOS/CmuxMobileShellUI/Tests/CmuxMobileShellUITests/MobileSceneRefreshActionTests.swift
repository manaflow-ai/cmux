import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileSceneRefreshActionTests {
    @Test func inactiveInterruptionDoesNotBecomeBackgroundTransition() {
        #expect(MobileSceneRefreshAction(scenePhase: .inactive) == .none)
        #expect(MobileSceneRefreshAction(scenePhase: .background) == .enterBackground)
        #expect(MobileSceneRefreshAction(scenePhase: .active) == .resumeForeground)
    }
}
