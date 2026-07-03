import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceToolbarLayoutPriorityTests {
    @Test func titleRoleHasLowerSwiftUILayoutPriorityThanTrailingControls() {
        #expect(
            MobileToolbarItemLayoutRole.compressibleTitle.swiftUILayoutPriority
                < MobileToolbarItemLayoutRole.fixedTrailingControls.swiftUILayoutPriority
        )
    }
}
