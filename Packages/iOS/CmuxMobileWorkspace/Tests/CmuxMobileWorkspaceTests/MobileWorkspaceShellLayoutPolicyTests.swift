import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileWorkspaceShellLayoutPolicyTests {
    @Test func compactHeightUsesStackWorkspaceNavigation() {
        #expect(
            MobileWorkspaceShellLayoutPolicy.usesCompactStack(
                hasCompactHorizontalSize: false,
                hasCompactVerticalSize: true
            )
        )
        #expect(
            MobileWorkspaceShellLayoutPolicy.usesCompactStack(
                hasCompactHorizontalSize: true,
                hasCompactVerticalSize: false
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.usesCompactStack(
                hasCompactHorizontalSize: false,
                hasCompactVerticalSize: false
            )
        )
    }
}
