import Testing
@testable import CmuxMobileShellUI

@Suite struct CmuxMobileShellUISmokeTests {
    @Test @MainActor func workspaceSettingsUsesConventionalSystemIcon() {
        #expect(MobileWorkspaceSettingsIcon.systemName == "gearshape")
    }
}
